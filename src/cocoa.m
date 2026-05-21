// cocoa.m — Cocoa side of go-fish.
//
// Responsibilities:
//   - NSApplication lifecycle (gf_run).
//   - Global CGEventTap intercepting Cmd+Tab / flag changes / Escape.
//   - Window enumeration via the Accessibility API (covers minimized windows).
//   - Thumbnail capture via CGWindowListCreateImage (still works as of macOS 14;
//     deprecation warning suppressed at the Go cgo level).
//   - The borderless floating NSPanel that draws the grid.
//   - Window activation via AX (handles un-minimize + raise; the system
//     switches Spaces when the owning app is activated).

#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#include "cocoa.h"
#include <dlfcn.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// CGWindowListCreateImage was obsoleted in the macOS 15 SDK headers, but the
// symbol is still present in CoreGraphics at runtime. Load it dynamically so
// the binary builds against any SDK. (Future: migrate to ScreenCaptureKit.)
typedef CGImageRef (*gf_clci_t)(CGRect, uint32_t /*CGWindowListOption*/,
                                CGWindowID, uint32_t /*CGWindowImageOption*/);
static gf_clci_t gCGWindowListCreateImage = NULL;
static void gf_loadSymbols(void) {
    if (!gCGWindowListCreateImage) {
        gCGWindowListCreateImage = (gf_clci_t)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
    }
}

// Private API. Maps an AX window element to its CGWindowID. Stable for ~15 years.
extern AXError _AXUIElementGetWindow(AXUIElementRef element, CGWindowID *out);

// Callbacks from Go.
extern int  gfOnHotkey(int shift, int scope);
extern int  gfOnCommit(void);
extern int  gfOnCancel(void);
extern void gfSetSelection(int idx);
extern int  gfOnClose(int idx);

// =========================================================================
// State (main thread only, unless noted).
// =========================================================================

static atomic_int        gActive = 0;          // 1 when panel is up.
static CFMachPortRef     gEventTap = NULL;
static CFRunLoopSourceRef gEventTapSrc = NULL;

@class GFPanelView;
static NSPanel     *gPanel = nil;
static GFPanelView *gPanelView = nil;

@class GFStatusHandler;
static NSStatusItem    *gStatusItem    = nil;
static GFStatusHandler *gStatusHandler = nil;

@class GFMRUTracker;
static NSMutableArray<NSNumber *>            *gMRU         = nil;  // CGWindowIDs, front-to-back MRU
static NSMutableDictionary<NSNumber *, id>   *gAXObservers = nil;  // pid -> AXObserverRef (bridged into ARC)
static GFMRUTracker                          *gMRUTracker  = nil;
static const NSUInteger                       kMRUCap      = 100;

// Thumbnail cache. Populated lazily as windows are focused or activated, and
// at startup via a staggered bootstrap pass. Touched only on the main thread.
static NSMutableDictionary<NSNumber *, NSImage *> *gThumbCache = nil; // winID -> NSImage
static NSMutableArray<NSNumber *>                 *gThumbLRU   = nil; // winIDs, oldest first
static NSMutableDictionary<NSNumber *, NSDate *>  *gThumbAge   = nil; // winID -> last-captured time
static const NSUInteger                            kThumbCap        = 30;
static const NSTimeInterval                        kThumbStaleAfter = 30.0; // seconds

// Forward declarations — these are used by the panel UI, which is defined
// before the thumbnail-cache and MRU sections.
static void gf_pushMRU(CGWindowID winID);
static void gf_captureAsync(CGWindowID winID);

// =========================================================================
// Permissions
// =========================================================================

int gf_hasAccessibility(void) {
    return AXIsProcessTrusted() ? 1 : 0;
}

void gf_promptAccessibility(void) {
    NSDictionary *opts = @{ (__bridge id)kAXTrustedCheckOptionPrompt: @YES };
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
}

int gf_hasScreenRecording(void) {
    if (@available(macOS 10.15, *)) {
        return CGPreflightScreenCaptureAccess() ? 1 : 0;
    }
    return 1;
}

void gf_promptScreenRecording(void) {
    if (@available(macOS 10.15, *)) {
        CGRequestScreenCaptureAccess();
    }
}

// =========================================================================
// Event tap — Cmd+Tab interception
// =========================================================================

static CGEventRef tapCallback(CGEventTapProxy proxy, CGEventType type,
                              CGEventRef event, void *refcon) {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (gEventTap) CGEventTapEnable(gEventTap, true);
        return event;
    }

    CGEventFlags flags = CGEventGetFlags(event);
    BOOL cmd   = (flags & kCGEventFlagMaskCommand) != 0;
    BOOL shift = (flags & kCGEventFlagMaskShift)   != 0;

    if (type == kCGEventKeyDown) {
        CGKeyCode key = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        if (cmd && key == 0x30 /* Tab */) {
            if (gfOnHotkey(shift ? 1 : 0, 0)) return NULL;
            return event;
        }
        if (cmd && key == 0x32 /* ` (grave) */) {
            if (gfOnHotkey(shift ? 1 : 0, 1)) return NULL;
            return event;
        }
        if (key == 0x35 /* Escape */ && atomic_load(&gActive)) {
            gfOnCancel();
            return NULL;
        }
    } else if (type == kCGEventFlagsChanged) {
        if (!cmd && atomic_load(&gActive)) {
            gfOnCommit();
        }
    }
    return event;
}

static void installEventTap(void) {
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventFlagsChanged);
    gEventTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
                                 kCGEventTapOptionDefault, mask, tapCallback, NULL);
    if (!gEventTap) {
        fprintf(stderr, "go-fish: failed to create event tap (Accessibility permission?)\n");
        return;
    }
    gEventTapSrc = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, gEventTap, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), gEventTapSrc, kCFRunLoopCommonModes);
    CGEventTapEnable(gEventTap, true);
}

// =========================================================================
// Window enumeration (AX-based; includes minimized)
// =========================================================================

int gf_frontmostPID(void) {
    NSRunningApplication *app = [[NSWorkspace sharedWorkspace] frontmostApplication];
    return app ? (int)app.processIdentifier : 0;
}

// Per-app AX messaging timeout. Keeps a single unresponsive app from stalling
// the entire window snapshot. The app still appears in the grid as a
// placeholder entry (unresponsive=1, axRef=NULL).
static const float kAXAppTimeout = 0.1f; // seconds

static void gf_ensureCap(gf_window_t **buf, int *cap, int needed) {
    if (needed <= *cap) return;
    int newCap = *cap > 0 ? *cap : 32;
    while (newCap < needed) newCap *= 2;
    *buf = (gf_window_t *)realloc(*buf, newCap * sizeof(gf_window_t));
    memset(*buf + *cap, 0, (newCap - *cap) * sizeof(gf_window_t));
    *cap = newCap;
}

gf_window_t *gf_enumerateWindows(int *out_count, int filterPID) {
    *out_count = 0;
    @autoreleasepool {
        // CGWindowID -> front-to-back-index map for sort + on-screen test.
        NSMutableDictionary<NSNumber *, NSNumber *> *cgIndex = [NSMutableDictionary dictionary];
        CFArrayRef cgList = CGWindowListCopyWindowInfo(
            kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
            kCGNullWindowID);
        if (cgList) {
            CFIndex n = CFArrayGetCount(cgList);
            for (CFIndex i = 0; i < n; i++) {
                NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(cgList, i);
                NSNumber *layer = info[(id)kCGWindowLayer];
                if (layer.intValue != 0) continue;
                NSNumber *wid = info[(id)kCGWindowNumber];
                if (wid && !cgIndex[wid]) cgIndex[wid] = @((int)i);
            }
            CFRelease(cgList);
        }

        // Grow a single C buffer directly — no NSDictionary intermediate.
        int cap = 0, count = 0;
        gf_window_t *out = NULL;
        gf_ensureCap(&out, &cap, 32);

        int fallbackZ = 0;
        NSArray<NSRunningApplication *> *apps = [[NSWorkspace sharedWorkspace] runningApplications];
        for (NSRunningApplication *app in apps) {
            pid_t pid = app.processIdentifier;
            if (filterPID != 0) {
                if (pid != filterPID) continue;
            } else if (app.activationPolicy != NSApplicationActivationPolicyRegular) {
                continue;
            }
            AXUIElementRef axApp = AXUIElementCreateApplication(pid);
            if (!axApp) continue;

            // Cap AX messaging time on this app so an unresponsive process
            // can't stall the panel. The same timeout propagates to child
            // window elements queried through axApp.
            AXUIElementSetMessagingTimeout(axApp, kAXAppTimeout);

            CFArrayRef axWins = NULL;
            AXError err = AXUIElementCopyAttributeValue(
                axApp, kAXWindowsAttribute, (CFTypeRef *)&axWins);

            if (err == kAXErrorCannotComplete) {
                // App didn't respond in time. Add a single placeholder so the
                // user can still see and (best-effort) activate it.
                if (app.localizedName.length == 0) {
                    CFRelease(axApp);
                    continue;
                }
                gf_ensureCap(&out, &cap, count + 1);
                gf_window_t *e = &out[count];
                e->pid          = (int)pid;
                e->axRef        = NULL;
                e->windowID     = 0;
                e->title        = strdup([app.localizedName UTF8String]);
                e->appName      = strdup([app.localizedName UTF8String]);
                e->minimized    = 0;
                e->onScreen     = 1;
                e->zOrder       = 900000 + fallbackZ;
                e->unresponsive = 1;
                count++;
                fallbackZ++;
                CFRelease(axApp);
                continue;
            }
            if (err != kAXErrorSuccess || !axWins) {
                CFRelease(axApp);
                continue;
            }
            CFIndex wc = CFArrayGetCount(axWins);
            for (CFIndex i = 0; i < wc; i++) {
                AXUIElementRef w = (AXUIElementRef)CFArrayGetValueAtIndex(axWins, i);

                // Read minimized state up front: minimized windows always pass
                // the subrole filter below, since some apps return them with
                // a non-standard subrole (or no subrole at all) once minimized.
                CFTypeRef minRef = NULL;
                AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute, &minRef);
                BOOL minimized = NO;
                if (minRef) {
                    minimized = CFBooleanGetValue((CFBooleanRef)minRef);
                    CFRelease(minRef);
                }

                if (!minimized) {
                    CFTypeRef subroleRef = NULL;
                    AXUIElementCopyAttributeValue(w, kAXSubroleAttribute, &subroleRef);
                    NSString *subrole = (__bridge_transfer NSString *)subroleRef;
                    if (subrole && ![subrole isEqualToString:(NSString *)kAXStandardWindowSubrole]) continue;
                }

                CFTypeRef titleRef = NULL;
                AXUIElementCopyAttributeValue(w, kAXTitleAttribute, &titleRef);
                NSString *title = (__bridge_transfer NSString *)titleRef;
                if (!title) title = @"";

                CGWindowID winID = 0;
                _AXUIElementGetWindow(w, &winID);

                NSNumber *order = winID ? cgIndex[@(winID)] : nil;
                BOOL onScreen = (order != nil) && !minimized;

                // Sort key: MRU position first, then z-order, then minimized.
                NSInteger mruPos = (winID && gMRU) ? [gMRU indexOfObject:@(winID)] : NSNotFound;
                int zOrder;
                if (mruPos != NSNotFound) {
                    zOrder = (int)mruPos;
                } else if (order) {
                    zOrder = 100000 + order.intValue;
                } else if (minimized) {
                    zOrder = 300000 + fallbackZ;
                } else {
                    zOrder = 200000 + fallbackZ;
                }
                fallbackZ++;

                if (title.length == 0 && app.localizedName.length == 0) continue;

                NSString *displayTitle = title.length > 0 ? title : app.localizedName;
                NSString *displayApp   = app.localizedName ?: @"";

                gf_ensureCap(&out, &cap, count + 1);
                gf_window_t *e = &out[count];
                e->pid          = (int)pid;
                e->axRef        = (void *)CFRetain(w);
                e->windowID     = winID;
                e->title        = strdup([displayTitle UTF8String]);
                e->appName      = strdup([displayApp UTF8String]);
                e->minimized    = minimized ? 1 : 0;
                e->onScreen     = onScreen ? 1 : 0;
                e->zOrder       = zOrder;
                e->unresponsive = 0;
                count++;
            }
            CFRelease(axWins);
            CFRelease(axApp);
        }

        if (count == 0) {
            free(out);
            return NULL;
        }
        *out_count = count;
        return out;
    }
}

void gf_release(void *axRef) {
    if (axRef) CFRelease((CFTypeRef)axRef);
}

// =========================================================================
// Panel UI
// =========================================================================

@interface GFEntry : NSObject
@property (nonatomic, copy)   NSString *title;
@property (nonatomic, copy)   NSString *appName;
@property (nonatomic, strong) NSImage  *image;
@property (nonatomic, assign) unsigned int windowID;
@property (nonatomic, assign) int pid;
@property (nonatomic, assign) BOOL minimized;
@property (nonatomic, assign) BOOL thumbLoaded;
@property (nonatomic, assign) BOOL unresponsive;
@end
@implementation GFEntry @end

@interface GFPanelView : NSView
@property (nonatomic, assign) NSInteger selected;
@property (nonatomic, strong) NSArray<GFEntry *> *entries;
@property (nonatomic, strong) NSTrackingArea *trackingArea;
- (void)updateSelection:(NSInteger)idx;
@end

// Layout values. Kept as a single struct so drawing and hit-testing agree.
// appH is the band above the thumbnail that holds the application name;
// titleH is the band below the thumbnail that holds the window title.
typedef struct {
    CGFloat margin, gap, titleH, appH;
    NSInteger cols;
    CGFloat tileW, tileH, cellH;
    CGFloat topY;
} gf_layout_t;

// Column count for an N-entry grid. Slight landscape bias (ratio target ~1.5)
// and capped at 7 to keep titles legible.
static NSInteger gf_pickCols(NSInteger n) {
    if (n <= 1) return MAX(n, (NSInteger)1);
    NSInteger cols = (NSInteger)ceil(sqrt((double)n * 1.5));
    if (cols < 1) cols = 1;
    if (cols > 7) cols = 7;
    if (cols > n) cols = n;
    return cols;
}

// Preferred panel size at full tile dimensions. Caller is responsible for
// clamping to screen bounds if the result is too large.
static NSSize gf_preferredPanelSize(NSInteger n) {
    if (n < 1) n = 1;
    CGFloat margin = 24, gap = 14, titleH = 22, appH = 20;
    CGFloat tileW = 240;
    CGFloat tileH = tileW * 0.65;
    CGFloat cellH = tileH + titleH + appH + 4;
    NSInteger cols = gf_pickCols(n);
    NSInteger rows = (n + cols - 1) / cols;
    CGFloat w = 2*margin + cols*tileW + (cols-1)*gap;
    CGFloat h = 2*margin + rows*cellH + (rows-1)*gap;
    return NSMakeSize(w, h);
}

@implementation GFPanelView

- (BOOL)isFlipped { return NO; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }

- (gf_layout_t)layoutForCount:(NSInteger)n {
    gf_layout_t L = {0};
    NSRect b = self.bounds;
    L.margin = 24;
    L.gap = 14;
    L.titleH = 22;
    L.appH = 20;
    L.cols = gf_pickCols(n);
    NSInteger rows = (n + L.cols - 1) / L.cols;

    CGFloat availW = b.size.width  - 2*L.margin;
    CGFloat availH = b.size.height - 2*L.margin;

    // tileW from each constraint; pick the smaller so every row fits and
    // nothing clips off the bottom of a clamped panel. tileH = tileW * 0.65.
    CGFloat tileWByWidth  = (availW - L.gap*(L.cols-1)) / L.cols;
    CGFloat innerCellH    = (availH - L.gap*(rows-1)) / rows;
    CGFloat tileWByHeight = (innerCellH - L.titleH - L.appH - 4) / 0.65;
    L.tileW = MIN(tileWByWidth, tileWByHeight);
    if (L.tileW < 60) L.tileW = 60;
    L.tileH = L.tileW * 0.65;
    L.cellH = L.tileH + L.titleH + L.appH + 4;

    CGFloat totalH = rows*L.cellH + (rows-1)*L.gap;
    L.topY = b.size.height/2 + totalH/2;
    return L;
}

// Image rect for tile i. Bottom of the tile is at the same y as the label,
// so the full clickable cell extends down by L.titleH.
- (NSRect)imageRectForIndex:(NSInteger)i layout:(gf_layout_t)L {
    NSInteger row = i / L.cols;
    NSInteger col = i % L.cols;
    CGFloat x = L.margin + col*(L.tileW + L.gap);
    CGFloat y = L.topY - (row+1)*L.cellH - row*L.gap;
    return NSMakeRect(x, y + L.titleH + 2, L.tileW, L.tileH);
}

- (NSRect)cellRectForIndex:(NSInteger)i layout:(gf_layout_t)L {
    NSRect r = [self imageRectForIndex:i layout:L];
    return NSMakeRect(r.origin.x, r.origin.y - L.titleH - 2,
                      r.size.width, r.size.height + L.titleH + L.appH + 4);
}

// Close-button rect for tile i, vertically centered in the app-name band so it
// sits to the left of the app name without overlapping the thumbnail itself.
- (NSRect)closeRectForIndex:(NSInteger)i layout:(gf_layout_t)L {
    NSRect r = [self imageRectForIndex:i layout:L];
    CGFloat d = MIN(16.0, L.appH - 4.0);
    if (d < 10.0) d = 10.0;
    CGFloat bandY = NSMaxY(r) + 2;             // bottom of the app-name band
    CGFloat y     = bandY + (L.appH - d) / 2;  // center vertically in the band
    return NSMakeRect(NSMinX(r), y, d, d);
}

- (NSInteger)indexAtPoint:(NSPoint)p layout:(gf_layout_t)L {
    NSInteger n = self.entries.count;
    for (NSInteger i = 0; i < n; i++) {
        if (NSPointInRect(p, [self cellRectForIndex:i layout:L])) return i;
    }
    return -1;
}

- (NSInteger)indexAtPoint:(NSPoint)p {
    NSInteger n = self.entries.count;
    if (n == 0) return -1;
    return [self indexAtPoint:p layout:[self layoutForCount:n]];
}

// Dirty just the previous-selected and new-selected cells (plus highlight
// outset) instead of the whole panel. Cuts hover-driven CPU significantly.
- (void)updateSelection:(NSInteger)idx {
    NSInteger prev = self.selected;
    if (prev == idx) return;
    self.selected = idx;
    NSInteger n = self.entries.count;
    if (n == 0) return;
    gf_layout_t L = [self layoutForCount:n];
    if (prev >= 0 && prev < n) {
        [self setNeedsDisplayInRect:
            NSInsetRect([self cellRectForIndex:prev layout:L], -6, -6)];
    }
    if (idx >= 0 && idx < n) {
        [self setNeedsDisplayInRect:
            NSInsetRect([self cellRectForIndex:idx layout:L], -6, -6)];
    }
}

// Cached drawing attributes — these dictionaries are immutable and used on
// every draw, so allocating them per frame (with mouseMoved hammering
// drawRect:) wastes a lot of autoreleased objects.
static NSDictionary *gTitleAttrs    = nil;
static NSDictionary *gAppAttrs      = nil;
static NSDictionary *gBadgeAttrs    = nil;
static NSDictionary *gWarnAttrs     = nil;
static void gf_initDrawAttrs(void) {
    if (gTitleAttrs) return;
    NSMutableParagraphStyle *para = [NSMutableParagraphStyle new];
    para.lineBreakMode = NSLineBreakByTruncatingTail;
    para.alignment = NSTextAlignmentCenter;
    gTitleAttrs = @{
        NSFontAttributeName:            [NSFont systemFontOfSize:12],
        NSForegroundColorAttributeName: [NSColor labelColor],
        NSParagraphStyleAttributeName:  para,
    };
    gAppAttrs = @{
        NSFontAttributeName:            [NSFont boldSystemFontOfSize:11],
        NSForegroundColorAttributeName: [NSColor secondaryLabelColor],
        NSParagraphStyleAttributeName:  para,
    };
    gBadgeAttrs = @{
        NSFontAttributeName:            [NSFont boldSystemFontOfSize:10],
        NSForegroundColorAttributeName: [NSColor secondaryLabelColor],
    };
    gWarnAttrs = @{
        NSFontAttributeName:            [NSFont boldSystemFontOfSize:10],
        NSForegroundColorAttributeName: [NSColor systemRedColor],
    };
}

- (void)drawRect:(NSRect)dirty {
    NSRect b = self.bounds;
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:b xRadius:14 yRadius:14];
    [[[NSColor windowBackgroundColor] colorWithAlphaComponent:0.92] setFill];
    [bg fill];

    NSInteger n = self.entries.count;
    if (n == 0) return;
    gf_layout_t L = [self layoutForCount:n];
    gf_initDrawAttrs();

    for (NSInteger i = 0; i < n; i++) {
        // Skip cells outside the dirty rect. Combined with cell-scoped dirty
        // marking in updateSelection:, this keeps mouseMoved redraws cheap.
        NSRect outsetCell = NSInsetRect([self cellRectForIndex:i layout:L], -6, -6);
        if (!NSIntersectsRect(outsetCell, dirty)) continue;

        NSRect imgR   = [self imageRectForIndex:i layout:L];
        NSRect closeR = [self closeRectForIndex:i layout:L];
        NSRect textR  = NSMakeRect(imgR.origin.x, imgR.origin.y - L.titleH - 2,
                                   imgR.size.width, L.titleH);
        CGFloat appPad = closeR.size.width + 4;
        CGFloat appW   = imgR.size.width - 2 * appPad;
        if (appW < 0) appW = 0;
        NSRect appR  = NSMakeRect(imgR.origin.x + appPad,
                                  imgR.origin.y + imgR.size.height + 2,
                                  appW, L.appH);

        GFEntry *e = self.entries[i];

        if (i == self.selected) {
            NSRect hi = NSInsetRect([self cellRectForIndex:i layout:L], -6, -6);
            NSBezierPath *h = [NSBezierPath bezierPathWithRoundedRect:hi xRadius:10 yRadius:10];
            [[[NSColor controlAccentColor] colorWithAlphaComponent:0.55] setFill];
            [h fill];
        }

        if (e.image) {
            NSSize is = e.image.size;
            NSSize ds;
            if (e.thumbLoaded) {
                CGFloat scale = MIN(imgR.size.width/is.width, imgR.size.height/is.height);
                ds = NSMakeSize(is.width*scale, is.height*scale);
            } else {
                CGFloat side = MIN(64.0, MIN(imgR.size.width, imgR.size.height) - 8);
                if (side < 16) side = 16;
                ds = NSMakeSize(side, side);
            }
            NSRect dr = NSMakeRect(imgR.origin.x + (imgR.size.width - ds.width)/2,
                                   imgR.origin.y + (imgR.size.height - ds.height)/2,
                                   ds.width, ds.height);
            [e.image drawInRect:dr fromRect:NSZeroRect
                      operation:NSCompositingOperationSourceOver fraction:e.unresponsive ? 0.7 : 1.0];
            if (e.unresponsive) {
                [@"not responding"
                    drawAtPoint:NSMakePoint(imgR.origin.x+4, imgR.origin.y+4)
                 withAttributes:gWarnAttrs];
            } else if (e.minimized) {
                [@"minimized"
                    drawAtPoint:NSMakePoint(imgR.origin.x+4, imgR.origin.y+4)
                 withAttributes:gBadgeAttrs];
            }
        }

        NSString *label = e.title.length > 0 ? e.title : e.appName;
        [label drawInRect:textR withAttributes:gTitleAttrs];
        if (e.appName.length > 0) {
            [e.appName drawInRect:appR withAttributes:gAppAttrs];
        }

        // Close button: only drawn for entries we can actually close (i.e.
        // not unresponsive placeholders, which have no AX ref).
        if (!e.unresponsive) {
            NSBezierPath *circle = [NSBezierPath bezierPathWithOvalInRect:closeR];
            [[NSColor colorWithWhite:0.0 alpha:0.60] setFill];
            [circle fill];
            [[NSColor colorWithWhite:1.0 alpha:0.95] setStroke];
            NSBezierPath *cross = [NSBezierPath bezierPath];
            cross.lineWidth = 1.5;
            cross.lineCapStyle = NSLineCapStyleRound;
            CGFloat pad = closeR.size.width * 0.30;
            [cross moveToPoint:NSMakePoint(NSMinX(closeR) + pad, NSMinY(closeR) + pad)];
            [cross lineToPoint:NSMakePoint(NSMaxX(closeR) - pad, NSMaxY(closeR) - pad)];
            [cross moveToPoint:NSMakePoint(NSMaxX(closeR) - pad, NSMinY(closeR) + pad)];
            [cross lineToPoint:NSMakePoint(NSMinX(closeR) + pad, NSMaxY(closeR) - pad)];
            [cross stroke];
        }
    }
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.trackingArea) [self removeTrackingArea:self.trackingArea];
    NSTrackingAreaOptions opts = NSTrackingMouseMoved
                               | NSTrackingActiveAlways
                               | NSTrackingInVisibleRect;
    self.trackingArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                     options:opts
                                                       owner:self
                                                    userInfo:nil];
    [self addTrackingArea:self.trackingArea];
}

- (void)mouseMoved:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    NSInteger idx = [self indexAtPoint:p];
    if (idx >= 0 && idx != self.selected) {
        // Drive selection through Go so state stays consistent;
        // it'll call back into gf_updateSelection to redraw.
        gfSetSelection((int)idx);
    }
}

- (void)mouseDown:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    NSInteger n = self.entries.count;
    if (n == 0) return;
    gf_layout_t L = [self layoutForCount:n];
    // Close-button hit-test first, but only for entries that actually draw an
    // X — unresponsive placeholders skip both the draw and the hit-test.
    for (NSInteger i = 0; i < n; i++) {
        GFEntry *ge = self.entries[i];
        if (ge.unresponsive) continue;
        if (NSPointInRect(p, [self closeRectForIndex:i layout:L])) {
            gfOnClose((int)i);
            return;
        }
    }
    NSInteger idx = [self indexAtPoint:p layout:L];
    if (idx < 0) return;
    gfSetSelection((int)idx);
    gfOnCommit();
}

@end

static void ensurePanel(void) {
    if (gPanel) return;
    // Placeholder size; gf_showPanel resizes the panel to fit the entry count
    // on every activation.
    NSRect r = NSMakeRect(0, 0, 600, 400);
    gPanel = [[NSPanel alloc] initWithContentRect:r
                                        styleMask:(NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel)
                                          backing:NSBackingStoreBuffered
                                            defer:NO];
    gPanel.level = NSPopUpMenuWindowLevel;
    gPanel.opaque = NO;
    gPanel.backgroundColor = [NSColor clearColor];
    gPanel.hasShadow = YES;
    gPanel.hidesOnDeactivate = NO;
    gPanel.releasedWhenClosed = NO;
    // Discard the window-server backing store when off-screen. The panel is
    // shown briefly and idle most of the time; reclaiming a ~10 MB retina
    // backing store between activations is worth the few-ms recreate cost.
    gPanel.oneShot = YES;
    gPanel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
                              | NSWindowCollectionBehaviorFullScreenAuxiliary
                              | NSWindowCollectionBehaviorStationary
                              | NSWindowCollectionBehaviorIgnoresCycle;
    [gPanel.contentView setWantsLayer:YES];
    gPanelView = [[GFPanelView alloc] initWithFrame:[gPanel.contentView bounds]];
    gPanelView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [gPanel.contentView addSubview:gPanelView];
}

// Builder state.
typedef struct {
    char         *title;
    char         *appName;
    void         *axRef;       // not retained here (Go owns); NULL if unresponsive
    unsigned int  windowID;
    int           minimized;
    int           pid;
    int           unresponsive;
} gf_pe_t;
typedef struct {
    gf_pe_t *entries;
    int      count;
} gf_pd_t;

void *gf_newPanelData(int count) {
    gf_pd_t *d = calloc(1, sizeof(gf_pd_t));
    d->entries = calloc(count > 0 ? count : 1, sizeof(gf_pe_t));
    d->count = count;
    return d;
}

void gf_setPanelEntry(void *data, int idx,
                      const char *title, const char *appName,
                      void *axRef, unsigned int windowID,
                      int minimized, int pid, int unresponsive) {
    gf_pd_t *d = (gf_pd_t *)data;
    d->entries[idx].title        = strdup(title ?: "");
    d->entries[idx].appName      = strdup(appName ?: "");
    d->entries[idx].axRef        = axRef;
    d->entries[idx].windowID     = windowID;
    d->entries[idx].minimized    = minimized;
    d->entries[idx].pid          = pid;
    d->entries[idx].unresponsive = unresponsive;
}

static void freePanelData(gf_pd_t *d) {
    if (!d) return;
    for (int i = 0; i < d->count; i++) {
        free(d->entries[i].title);
        free(d->entries[i].appName);
    }
    free(d->entries);
    free(d);
}

// Main-thread only. Build GFEntry objects from panel data, populating thumbs
// from the cache when present and falling back to the app icon otherwise.
static NSArray<GFEntry *> *gf_buildEntries(gf_pd_t *d) {
    NSMutableArray<GFEntry *> *items = [NSMutableArray arrayWithCapacity:d->count];
    for (int i = 0; i < d->count; i++) {
        gf_pe_t *e = &d->entries[i];
        GFEntry *ge = [GFEntry new];
        ge.title        = [NSString stringWithUTF8String:e->title];
        ge.appName      = [NSString stringWithUTF8String:e->appName];
        ge.windowID     = e->windowID;
        ge.pid          = e->pid;
        ge.minimized    = e->minimized != 0;
        ge.unresponsive = e->unresponsive != 0;

        NSImage *cached = nil;
        if (!ge.minimized && e->windowID != 0) {
            cached = gThumbCache[@(e->windowID)];
        }
        if (cached) {
            ge.image      = cached;
            ge.thumbLoaded = YES;
            NSNumber *key = @(e->windowID);
            [gThumbLRU removeObject:key];
            [gThumbLRU addObject:key];
        } else {
            NSRunningApplication *app = [NSRunningApplication
                runningApplicationWithProcessIdentifier:(pid_t)e->pid];
            ge.image = app.icon;
        }
        [items addObject:ge];
    }
    return items;
}

// Main-thread only. Kick off background thumbnail refresh for any cache
// misses or stale entries. Each completion path updates the live panel.
static void gf_fireCaptureRefresh(NSArray<GFEntry *> *items) {
    NSDate *now = [NSDate date];
    for (GFEntry *e in items) {
        if (e.minimized || e.windowID == 0 || e.unresponsive) continue;
        if (!e.thumbLoaded) {
            gf_captureAsync(e.windowID);
            continue;
        }
        NSDate *age = gThumbAge[@(e.windowID)];
        if (!age || [now timeIntervalSinceDate:age] > kThumbStaleAfter) {
            gf_captureAsync(e.windowID);
        }
    }
}

void gf_showPanel(void *data, int selected) {
    gf_pd_t *d = (gf_pd_t *)data;
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            ensurePanel();

            NSArray<GFEntry *> *items = gf_buildEntries(d);
            gPanelView.entries  = items;
            gPanelView.selected = selected;

            // Size + center on the screen under the cursor.
            NSSize ps = gf_preferredPanelSize(d->count);
            NSPoint cursor = [NSEvent mouseLocation];
            NSScreen *screen = [NSScreen mainScreen];
            for (NSScreen *s in [NSScreen screens]) {
                if (NSPointInRect(cursor, s.frame)) { screen = s; break; }
            }
            NSRect vf = screen.visibleFrame;
            CGFloat maxW = vf.size.width * 0.9;
            CGFloat maxH = vf.size.height * 0.85;
            if (ps.width  > maxW) ps.width  = maxW;
            if (ps.height > maxH) ps.height = maxH;
            NSRect r = NSMakeRect(vf.origin.x + (vf.size.width  - ps.width)/2,
                                  vf.origin.y + (vf.size.height - ps.height)/2,
                                  ps.width, ps.height);
            [gPanel setFrame:r display:NO];

            [gPanelView setNeedsDisplay:YES];
            [gPanel orderFrontRegardless];
            atomic_store(&gActive, 1);

            gf_fireCaptureRefresh(items);
            freePanelData(d);
        }
    });
}

// In-place entry refresh used by gfOnClose. Skips the resize/recenter so the
// panel doesn't visually jump after each X-click, and skips capture refresh
// because the captures fired by the initial show are still in flight.
void gf_updatePanelEntries(void *data, int selected) {
    gf_pd_t *d = (gf_pd_t *)data;
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            if (!gPanelView) { freePanelData(d); return; }
            gPanelView.entries  = gf_buildEntries(d);
            gPanelView.selected = selected;
            [gPanelView setNeedsDisplay:YES];
            freePanelData(d);
        }
    });
}

void gf_updateSelection(int selected) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gPanelView) return;
        [gPanelView updateSelection:selected];
    });
}

void gf_hidePanel(void) {
    atomic_store(&gActive, 0);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gPanelView) {
            // Drop NSImage refs immediately so their CGImage bitmaps can be
            // freed; on retina screens these add up fast (~800 KB each).
            for (GFEntry *e in gPanelView.entries) { e.image = nil; }
            gPanelView.entries = nil;
            [gPanelView setNeedsDisplay:YES];
        }
        if (gPanel) [gPanel orderOut:nil];
    });
}

// =========================================================================
// Activation
// =========================================================================

void gf_activateWindow(void *axRefPtr, int pid, int minimized) {
    // Unresponsive-app placeholder: no AX ref, just bring the app forward.
    if (!axRefPtr) {
        if (pid <= 0) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            @autoreleasepool {
                NSRunningApplication *app = [NSRunningApplication
                    runningApplicationWithProcessIdentifier:(pid_t)pid];
                [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
            }
        });
        return;
    }
    AXUIElementRef w = (AXUIElementRef)axRefPtr;
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            // Push to the MRU front immediately, before activation. We can't
            // rely on the notification path here: switching between windows
            // of the already-frontmost app fires no NSWorkspace notification,
            // and the AX kAXFocusedWindowChangedNotification arrives async
            // (sometimes after the user's next hotkey press). Doing it
            // eagerly makes quick Cmd+` toggling behave correctly.
            CGWindowID winID = 0;
            _AXUIElementGetWindow(w, &winID);
            if (winID != 0) {
                gf_pushMRU(winID);
                gf_captureAsync(winID);
            }

            if (minimized) {
                AXUIElementSetAttributeValue(w, kAXMinimizedAttribute, kCFBooleanFalse);
            }
            AXUIElementSetAttributeValue(w, kAXMainAttribute,    kCFBooleanTrue);
            AXUIElementSetAttributeValue(w, kAXFocusedAttribute, kCFBooleanTrue);
            AXUIElementPerformAction(w, kAXRaiseAction);
            NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:(pid_t)pid];
            [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
            CFRelease(w);
        }
    });
}

void gf_closeWindow(void *axRefPtr) {
    if (!axRefPtr) return;
    // Retain because the caller may release its own reference before this
    // block runs on the main queue.
    AXUIElementRef w = (AXUIElementRef)CFRetain((CFTypeRef)axRefPtr);
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            AXUIElementRef closeBtn = NULL;
            AXError err = AXUIElementCopyAttributeValue(
                w, kAXCloseButtonAttribute, (CFTypeRef *)&closeBtn);
            if (err == kAXErrorSuccess && closeBtn) {
                AXUIElementPerformAction(closeBtn, kAXPressAction);
                CFRelease(closeBtn);
            }
            CFRelease(w);
        }
    });
}

// qsort comparator: ascending by zOrder (frontmost first).
static int gf_cmpZOrder(const void *a, const void *b) {
    int za = ((const gf_window_t *)a)->zOrder;
    int zb = ((const gf_window_t *)b)->zOrder;
    return (za > zb) - (za < zb);
}

void gf_minimizeAll(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            int n = 0;
            gf_window_t *w = gf_enumerateWindows(&n, 0);
            if (!w) return;
            for (int i = 0; i < n; i++) {
                if (!w[i].minimized && w[i].axRef) {
                    AXUIElementSetAttributeValue(
                        (AXUIElementRef)w[i].axRef,
                        kAXMinimizedAttribute, kCFBooleanTrue);
                }
                free(w[i].title);
                free(w[i].appName);
                if (w[i].axRef) gf_release(w[i].axRef);
            }
            free(w);
        }
    });
}

// Best-effort un-fullscreen. Some apps expose kAXFullScreenAttribute and let
// us toggle it; if they do and the window is full-screen, flip it back to
// windowed so the subsequent position-set has a chance of taking effect.
static BOOL gf_isFullScreen(AXUIElementRef ax) {
    CFTypeRef fs = NULL;
    AXError err = AXUIElementCopyAttributeValue(ax,
        CFSTR("AXFullScreen"), &fs);
    BOOL out = NO;
    if (err == kAXErrorSuccess && fs) {
        if (CFGetTypeID(fs) == CFBooleanGetTypeID()) {
            out = CFBooleanGetValue((CFBooleanRef)fs);
        }
        CFRelease(fs);
    }
    return out;
}

void gf_cascadeAll(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            int n = 0;
            gf_window_t *w = gf_enumerateWindows(&n, 0);
            if (!w) return;
            // Front-to-back, so the first iteration ends up at the cascade
            // origin and later windows tuck behind it.
            qsort(w, n, sizeof(gf_window_t), gf_cmpZOrder);

            // Cascade onto the screen under the mouse.
            NSPoint cursor = [NSEvent mouseLocation];
            NSScreen *screen = [NSScreen mainScreen];
            for (NSScreen *s in [NSScreen screens]) {
                if (NSPointInRect(cursor, s.frame)) { screen = s; break; }
            }
            NSRect vf = screen.visibleFrame;

            // AX uses a y-down coordinate space with origin at the primary
            // screen's top-left; AppKit uses y-up with origin at the primary
            // screen's bottom-left. Convert vf's top-left into AX space.
            CGFloat primaryH = [[NSScreen screens] firstObject].frame.size.height;
            CGFloat axStartX = vf.origin.x;
            CGFloat axStartY = primaryH - (vf.origin.y + vf.size.height);

            CGFloat offset  = 32.0;
            // Wrap the staircase when it would push windows off the visible
            // area, leaving ~300pt of vertical room for the trailing window's
            // content to remain visible.
            CGFloat budget  = MAX(vf.size.height - 300.0, offset * 2);
            int     maxStep = MAX(1, (int)(budget / offset));

            // Uniform target size: 75% of the visible area, clamped to
            // sensible bounds so windows aren't huge on big displays or
            // unusable on small ones.
            CGFloat targetW = vf.size.width  * 0.75;
            CGFloat targetH = vf.size.height * 0.75;
            if (targetW > 1600) targetW = 1600;
            if (targetH > 1000) targetH = 1000;
            if (targetW < 480)  targetW = 480;
            if (targetH < 320)  targetH = 320;

            int moved = 0, resized = 0, skipped = 0;
            for (int i = 0; i < n; i++) {
                AXUIElementRef ax = (AXUIElementRef)w[i].axRef;
                if (!ax) { skipped++; continue; }

                if (w[i].minimized) {
                    AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute,
                                                 kCFBooleanFalse);
                }
                if (gf_isFullScreen(ax)) {
                    AXUIElementSetAttributeValue(ax,
                        CFSTR("AXFullScreen"), kCFBooleanFalse);
                }

                Boolean settable = false;
                AXError serr = AXUIElementIsAttributeSettable(ax,
                    kAXPositionAttribute, &settable);
                if (serr != kAXErrorSuccess || !settable) {
                    fprintf(stderr,
                        "go-fish cascade: skipping \"%s\" (%s) — position not settable (err=%d settable=%d)\n",
                        w[i].title ?: "", w[i].appName ?: "",
                        (int)serr, (int)settable);
                    skipped++;
                    continue;
                }

                // Reversed order: back-most window (highest zOrder) lands at
                // the top-left, each more-front window steps down-right. This
                // way every window's title bar peeks out above the one in
                // front of it, since z-order is preserved.
                int step = (n - 1 - i) % maxStep;
                CGPoint pt = CGPointMake(axStartX + offset * step,
                                         axStartY + offset * step);
                AXValueRef ptVal = AXValueCreate(kAXValueCGPointType, &pt);
                if (!ptVal) { skipped++; continue; }
                AXError perr = AXUIElementSetAttributeValue(ax,
                    kAXPositionAttribute, ptVal);
                CFRelease(ptVal);
                if (perr != kAXErrorSuccess) {
                    fprintf(stderr,
                        "go-fish cascade: failed to move \"%s\" (%s) — AXError=%d\n",
                        w[i].title ?: "", w[i].appName ?: "", (int)perr);
                    skipped++;
                    continue;
                }
                moved++;

                // Resize is best-effort and independent of the move. Some
                // apps (Calculator, Maps, fixed-UI Electron tools) refuse
                // size writes; the cascade position still lands either way.
                Boolean szSettable = false;
                AXError szerr = AXUIElementIsAttributeSettable(ax,
                    kAXSizeAttribute, &szSettable);
                if (szerr == kAXErrorSuccess && szSettable) {
                    CGSize sz = CGSizeMake(targetW, targetH);
                    AXValueRef szVal = AXValueCreate(kAXValueCGSizeType, &sz);
                    if (szVal) {
                        AXError rerr = AXUIElementSetAttributeValue(ax,
                            kAXSizeAttribute, szVal);
                        CFRelease(szVal);
                        if (rerr == kAXErrorSuccess) {
                            resized++;
                        } else {
                            fprintf(stderr,
                                "go-fish cascade: resize rejected for \"%s\" (%s) — AXError=%d\n",
                                w[i].title ?: "", w[i].appName ?: "", (int)rerr);
                        }
                    }
                } else {
                    fprintf(stderr,
                        "go-fish cascade: size not settable for \"%s\" (%s) — err=%d settable=%d\n",
                        w[i].title ?: "", w[i].appName ?: "",
                        (int)szerr, (int)szSettable);
                }
            }
            fprintf(stderr,
                    "go-fish cascade: moved %d, resized %d, skipped %d of %d (target %.0fx%.0f)\n",
                    moved, resized, skipped, n, targetW, targetH);

            for (int i = 0; i < n; i++) {
                free(w[i].title);
                free(w[i].appName);
                if (w[i].axRef) gf_release(w[i].axRef);
            }
            free(w);
        }
    });
}

// =========================================================================
// Thumbnail cache
// =========================================================================

// Downscale a captured CGImage into a max-600px NSImage with the same alpha
// + downsample logic the inline capture path used to do.
static NSImage *gf_makeThumbFromCG(CGImageRef src) {
    if (!src) return nil;
    size_t sw = CGImageGetWidth(src), sh = CGImageGetHeight(src);
    const size_t kMaxDim = 600;
    CGFloat scale = MIN((CGFloat)kMaxDim / sw, (CGFloat)kMaxDim / sh);
    CGImageRef thumb = NULL;
    if (scale >= 1.0) {
        thumb = CGImageRetain(src);
    } else {
        size_t dw = MAX((size_t)1, (size_t)(sw * scale));
        size_t dh = MAX((size_t)1, (size_t)(sh * scale));
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(NULL, dw, dh, 8, 0, cs,
            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(cs);
        if (ctx) {
            CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
            CGContextDrawImage(ctx, CGRectMake(0, 0, dw, dh), src);
            thumb = CGBitmapContextCreateImage(ctx);
            CGContextRelease(ctx);
        }
    }
    if (!thumb) return nil;
    NSImage *ns = [[NSImage alloc] initWithCGImage:thumb
                                              size:NSMakeSize(CGImageGetWidth(thumb),
                                                              CGImageGetHeight(thumb))];
    CGImageRelease(thumb);
    return ns;
}

// Synchronous capture (callable from any queue). nil on failure.
static NSImage *gf_captureSync(CGWindowID winID) {
    if (winID == 0 || !gCGWindowListCreateImage) return nil;
    CGImageRef src = gCGWindowListCreateImage(
        CGRectNull,
        kCGWindowListOptionIncludingWindow,
        winID,
        kCGWindowImageBoundsIgnoreFraming | kCGWindowImageNominalResolution);
    if (!src) return nil;
    NSImage *thumb = gf_makeThumbFromCG(src);
    CGImageRelease(src);
    return thumb;
}

// Main thread only: insert into the cache with LRU bookkeeping.
static void gf_storeThumb(CGWindowID winID, NSImage *thumb) {
    if (!thumb || winID == 0 || !gThumbCache) return;
    NSNumber *key = @(winID);
    gThumbCache[key] = thumb;
    gThumbAge[key]   = [NSDate date];
    [gThumbLRU removeObject:key];
    [gThumbLRU addObject:key];
    while (gThumbLRU.count > kThumbCap) {
        NSNumber *oldest = gThumbLRU.firstObject;
        if (!oldest) break;
        [gThumbCache removeObjectForKey:oldest];
        [gThumbAge   removeObjectForKey:oldest];
        [gThumbLRU   removeObjectAtIndex:0];
    }
}

// Capture in background, then cache + refresh the visible panel entry (if any).
static void gf_captureAsync(CGWindowID winID) {
    if (winID == 0 || !gCGWindowListCreateImage) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        @autoreleasepool {
            NSImage *thumb = gf_captureSync(winID);
            if (!thumb) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                @autoreleasepool {
                    gf_storeThumb(winID, thumb);
                    if (atomic_load(&gActive) && gPanelView) {
                        for (GFEntry *e in gPanelView.entries) {
                            if (e.windowID == winID) {
                                e.image = thumb;
                                e.thumbLoaded = YES;
                                [gPanelView setNeedsDisplay:YES];
                                break;
                            }
                        }
                    }
                }
            });
        }
    });
}

// Startup pre-warm. Serialized through a utility-priority queue so all the
// CGImage captures don't pile up in memory simultaneously.
static void gf_bootstrapCapture(void) {
    NSArray<NSNumber *> *ids = [gMRU copy];
    if (ids.count == 0) return;
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("gofish.thumbcapture.bootstrap", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(q, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    });
    for (NSNumber *wid in ids) {
        CGWindowID winID = wid.unsignedIntValue;
        dispatch_async(q, ^{
            @autoreleasepool {
                NSImage *thumb = gf_captureSync(winID);
                if (!thumb) return;
                dispatch_async(dispatch_get_main_queue(), ^{
                    gf_storeThumb(winID, thumb);
                });
            }
        });
    }
}

// =========================================================================
// MRU tracking
//
// We sort the switcher grid by most-recently-used so that the second entry
// (selected on first Cmd+Tab) is the previously-focused window — i.e. a
// quick Cmd+Tab toggles between the last two windows the user touched.
//
// Sources of MRU updates, all delivered on the main thread:
//   - NSWorkspaceDidActivateApplicationNotification: an app came forward.
//   - AXObserver(kAXFocusedWindowChangedNotification): user moved focus
//     between windows of the same app (e.g. clicked another window, used
//     in-app Cmd+`, etc.).
//
// We identify windows by CGWindowID, resolved from an AXUIElement via the
// long-stable private _AXUIElementGetWindow. Stale IDs (app quit) are
// harmless — they sit in the list but never match a live window.
// =========================================================================

static void gf_pushMRU(CGWindowID winID) {
    if (winID == 0 || !gMRU) return;
    NSNumber *boxed = @(winID);
    [gMRU removeObject:boxed];
    [gMRU insertObject:boxed atIndex:0];
    while (gMRU.count > kMRUCap) [gMRU removeLastObject];
}

// Resolve the currently focused window of an app (by pid) to a CGWindowID.
static CGWindowID gf_focusedWindowForPID(pid_t pid) {
    AXUIElementRef axApp = AXUIElementCreateApplication(pid);
    if (!axApp) return 0;
    CFTypeRef focused = NULL;
    AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute, &focused);
    CGWindowID winID = 0;
    if (focused) {
        _AXUIElementGetWindow((AXUIElementRef)focused, &winID);
        CFRelease(focused);
    }
    CFRelease(axApp);
    return winID;
}

// AX observer callback. `element` is normally the newly-focused window, but
// some apps deliver the AX app element instead — handle both.
static void gf_axObserverCallback(AXObserverRef obs, AXUIElementRef element,
                                  CFStringRef notif, void *ctx) {
    if (!CFEqual(notif, kAXFocusedWindowChangedNotification)) return;
    CGWindowID winID = 0;
    _AXUIElementGetWindow(element, &winID);
    if (winID == 0) {
        CFTypeRef focused = NULL;
        AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute, &focused);
        if (focused) {
            _AXUIElementGetWindow((AXUIElementRef)focused, &winID);
            CFRelease(focused);
        }
    }
    if (winID != 0) {
        gf_pushMRU(winID);
        gf_captureAsync(winID);
    }
}

static void gf_installObserverForPID(pid_t pid) {
    if (!gAXObservers || gAXObservers[@(pid)]) return;
    AXObserverRef observer = NULL;
    if (AXObserverCreate(pid, gf_axObserverCallback, &observer) != kAXErrorSuccess || !observer) {
        return;
    }
    AXUIElementRef axApp = AXUIElementCreateApplication(pid);
    if (!axApp) {
        CFRelease(observer);
        return;
    }
    // Best-effort: not every app accepts the observation (e.g. unresponsive apps).
    AXObserverAddNotification(observer, axApp, kAXFocusedWindowChangedNotification, NULL);
    CFRelease(axApp);
    CFRunLoopAddSource(CFRunLoopGetMain(),
                       AXObserverGetRunLoopSource(observer),
                       kCFRunLoopDefaultMode);
    gAXObservers[@(pid)] = (__bridge_transfer id)observer; // ARC owns from here
}

static void gf_uninstallObserverForPID(pid_t pid) {
    if (!gAXObservers) return;
    id boxed = gAXObservers[@(pid)];
    if (!boxed) return;
    AXObserverRef obs = (__bridge AXObserverRef)boxed;
    CFRunLoopRemoveSource(CFRunLoopGetMain(),
                          AXObserverGetRunLoopSource(obs),
                          kCFRunLoopDefaultMode);
    [gAXObservers removeObjectForKey:@(pid)];
}

@interface GFMRUTracker : NSObject
- (void)appActivated:(NSNotification *)note;
- (void)appLaunched:(NSNotification *)note;
- (void)appTerminated:(NSNotification *)note;
@end

@implementation GFMRUTracker

- (void)appActivated:(NSNotification *)note {
    NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
    if (!app) return;
    pid_t pid = app.processIdentifier;
    CGWindowID winID = gf_focusedWindowForPID(pid);
    if (winID != 0) {
        gf_pushMRU(winID);
        gf_captureAsync(winID);
    }
    gf_installObserverForPID(pid); // in case it's a freshly-regular app
}

- (void)appLaunched:(NSNotification *)note {
    NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
    if (!app || app.activationPolicy != NSApplicationActivationPolicyRegular) return;
    gf_installObserverForPID(app.processIdentifier);
}

- (void)appTerminated:(NSNotification *)note {
    NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
    if (!app) return;
    gf_uninstallObserverForPID(app.processIdentifier);
}

@end

static void gf_setupMRUTracking(void) {
    gMRU         = [NSMutableArray array];
    gAXObservers = [NSMutableDictionary dictionary];
    gMRUTracker  = [GFMRUTracker new];
    gThumbCache  = [NSMutableDictionary dictionary];
    gThumbLRU    = [NSMutableArray array];
    gThumbAge    = [NSMutableDictionary dictionary];

    NSNotificationCenter *nc = [[NSWorkspace sharedWorkspace] notificationCenter];
    [nc addObserver:gMRUTracker selector:@selector(appActivated:)
               name:NSWorkspaceDidActivateApplicationNotification object:nil];
    [nc addObserver:gMRUTracker selector:@selector(appLaunched:)
               name:NSWorkspaceDidLaunchApplicationNotification    object:nil];
    [nc addObserver:gMRUTracker selector:@selector(appTerminated:)
               name:NSWorkspaceDidTerminateApplicationNotification object:nil];

    // Bootstrap: install observers for every running regular app and seed
    // the MRU with the current z-order so the very first activation has a
    // reasonable list even before any focus event has fired.
    for (NSRunningApplication *app in [[NSWorkspace sharedWorkspace] runningApplications]) {
        if (app.activationPolicy == NSApplicationActivationPolicyRegular) {
            gf_installObserverForPID(app.processIdentifier);
        }
    }
    CFArrayRef cgList = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    if (cgList) {
        CFIndex n = CFArrayGetCount(cgList);
        for (CFIndex i = 0; i < n; i++) {
            NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(cgList, i);
            if ([info[(id)kCGWindowLayer] intValue] != 0) continue;
            NSNumber *wid = info[(id)kCGWindowNumber];
            if (wid && ![gMRU containsObject:wid]) [gMRU addObject:wid];
        }
        CFRelease(cgList);
    }

    // Pre-warm the thumbnail cache for the windows visible at launch.
    gf_bootstrapCapture();
}

// =========================================================================
// Menu-bar status item
// =========================================================================

@interface GFStatusHandler : NSObject
- (void)showGrid:(id)sender;
- (void)minimizeAll:(id)sender;
- (void)cascadeAll:(id)sender;
- (void)quit:(id)sender;
@end

@implementation GFStatusHandler
- (void)showGrid:(id)sender {
    // If the grid is somehow already up, close it first so this acts as a
    // clean re-open rather than triggering a cycle.
    if (atomic_load(&gActive)) gfOnCancel();
    gfOnHotkey(0, 0);
}
- (void)minimizeAll:(id)sender { gf_minimizeAll(); }
- (void)cascadeAll:(id)sender  { gf_cascadeAll();  }
- (void)quit:(id)sender {
    [NSApp terminate:nil];
}
@end

// Build a template menu-bar image from arbitrary image bytes.
//
// Two source shapes are supported:
//   * Transparent-background images (e.g. PNG with an alpha channel) —
//     used directly; alpha already encodes the silhouette.
//   * Opaque-background images (e.g. JPEG, black-on-white) — we convert
//     luminance into alpha so the bright background becomes transparent
//     and the dark strokes stay opaque.
//
// Template images pick up the menu bar's foreground color automatically
// in light/dark mode + on hover/highlight.
static NSImage *gf_makeMenuIcon(const void *bytes, int len) {
    if (!bytes || len <= 0) return nil;
    NSData *data = [NSData dataWithBytes:bytes length:len];
    NSImage *raw = [[NSImage alloc] initWithData:data];
    if (!raw) return nil;
    CGImageRef src = [raw CGImageForProposedRect:NULL context:nil hints:nil];
    if (!src) return raw;

    CGImageAlphaInfo info = CGImageGetAlphaInfo(src);
    BOOL srcHasAlpha = !(info == kCGImageAlphaNone        ||
                         info == kCGImageAlphaNoneSkipFirst ||
                         info == kCGImageAlphaNoneSkipLast);

    // Render into an RGBA bitmap at a size that comfortably exceeds the
    // menu bar's height.
    size_t sw = CGImageGetWidth(src), sh = CGImageGetHeight(src);
    const size_t maxDim = 64;
    CGFloat scale = MIN((CGFloat)maxDim / sw, (CGFloat)maxDim / sh);
    if (scale > 1) scale = 1;
    size_t dw = MAX((size_t)1, (size_t)(sw * scale));
    size_t dh = MAX((size_t)1, (size_t)(sh * scale));

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, dw, dh, 8, dw*4, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return raw;

    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(0, 0, dw, dh), src);

    if (!srcHasAlpha) {
        // Opaque source: derive alpha from luminance, force RGB → black.
        uint8_t *px = (uint8_t *)CGBitmapContextGetData(ctx);
        size_t stride = CGBitmapContextGetBytesPerRow(ctx);
        for (size_t y = 0; y < dh; y++) {
            uint8_t *row = px + y*stride;
            for (size_t x = 0; x < dw; x++) {
                uint8_t *p = row + x*4;
                uint16_t luma = (uint16_t)p[0] + p[1] + p[2];
                uint8_t  a    = (uint8_t)(255 - (luma / 3));
                p[0] = 0; p[1] = 0; p[2] = 0; p[3] = a;
            }
        }
    }

    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    NSImage *icon = [[NSImage alloc] initWithCGImage:out size:NSMakeSize(18, 18)];
    CGImageRelease(out);
    icon.template = YES;
    return icon;
}

static void installStatusItem(const void *iconBytes, int iconLen) {
    NSImage *icon = gf_makeMenuIcon(iconBytes, iconLen);
    gStatusHandler = [GFStatusHandler new];
    gStatusItem = [[NSStatusBar systemStatusBar]
        statusItemWithLength:NSVariableStatusItemLength];
    gStatusItem.button.image   = icon;
    gStatusItem.button.toolTip = @"go-fish";

    NSMenu *menu = [[NSMenu alloc] init];
    NSMenuItem *showItem = [[NSMenuItem alloc] initWithTitle:@"Show Window Grid"
                                                      action:@selector(showGrid:)
                                               keyEquivalent:@""];
    showItem.target = gStatusHandler;
    [menu addItem:showItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *minItem = [[NSMenuItem alloc] initWithTitle:@"Minimize All"
                                                     action:@selector(minimizeAll:)
                                              keyEquivalent:@""];
    minItem.target = gStatusHandler;
    [menu addItem:minItem];

    NSMenuItem *cascadeItem = [[NSMenuItem alloc] initWithTitle:@"Cascade All"
                                                         action:@selector(cascadeAll:)
                                                  keyEquivalent:@""];
    cascadeItem.target = gStatusHandler;
    [menu addItem:cascadeItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit"
                                                      action:@selector(quit:)
                                               keyEquivalent:@"q"];
    quitItem.target = gStatusHandler;
    [menu addItem:quitItem];
    gStatusItem.menu = menu; // clicking the icon now pops this menu
}

// =========================================================================
// Run loop
// =========================================================================

void gf_run(const void *iconBytes, int iconLen) {
    @autoreleasepool {
        // Inner pool: drains setup-time temporaries (the icon JPEG NSData,
        // the bootstrap NSArray of running apps, etc.) before [app run]
        // takes over the thread for the lifetime of the process.
        @autoreleasepool {
            gf_loadSymbols();
            NSApplication *app = [NSApplication sharedApplication];
            // Accessory: no Dock icon, no app menu; status item still shows.
            [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
            gf_setupMRUTracking();
            installStatusItem(iconBytes, iconLen);
            installEventTap();
        }
        [NSApp run];
    }
}
