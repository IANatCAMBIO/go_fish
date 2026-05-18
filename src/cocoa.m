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

gf_window_t *gf_enumerateWindows(int *out_count, int filterPID) {
    *out_count = 0;
    @autoreleasepool {
        // First, build a CGWindowID -> front-to-back-index map for sort + on-screen test.
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

        NSMutableArray *result = [NSMutableArray array];
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
            CFArrayRef axWins = NULL;
            AXError err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute, (CFTypeRef *)&axWins);
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
                    // Subrole filter (visible windows only): keep standard
                    // windows, drop palettes / dialogs / tooltips.
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
                // Lower = closer to front of the switcher.
                NSInteger mruPos = (winID && gMRU) ? [gMRU indexOfObject:@(winID)] : NSNotFound;
                int zOrder;
                if (mruPos != NSNotFound) {
                    zOrder = (int)mruPos;                  // 0..kMRUCap
                } else if (order) {
                    zOrder = 100000 + order.intValue;      // visible but never touched
                } else if (minimized) {
                    zOrder = 300000 + fallbackZ;           // minimized, unknown to MRU
                } else {
                    zOrder = 200000 + fallbackZ;           // off-Space, unknown to MRU
                }
                fallbackZ++;

                // Skip windows with no title AND no app name — usually noise.
                if (title.length == 0 && app.localizedName.length == 0) continue;

                NSString *displayTitle = title.length > 0 ? title : app.localizedName;
                NSString *displayApp   = app.localizedName ?: @"";

                NSValue *axBoxed = [NSValue valueWithPointer:(const void *)CFRetain(w)];
                [result addObject:@{
                    @"title":     displayTitle,
                    @"appName":   displayApp,
                    @"axRef":     axBoxed,
                    @"windowID":  @(winID),
                    @"minimized": @(minimized),
                    @"onScreen":  @(onScreen),
                    @"zOrder":    @(zOrder),
                    @"pid":       @((int)pid),
                }];
            }
            CFRelease(axWins);
            CFRelease(axApp);
        }

        if (result.count == 0) return NULL;
        gf_window_t *out = calloc(result.count, sizeof(gf_window_t));
        for (NSUInteger i = 0; i < result.count; i++) {
            NSDictionary *e = result[i];
            out[i].pid       = [e[@"pid"] intValue];
            out[i].axRef     = [e[@"axRef"] pointerValue]; // retained
            out[i].windowID  = [e[@"windowID"] unsignedIntValue];
            out[i].title     = strdup([e[@"title"] UTF8String]);
            out[i].appName   = strdup([e[@"appName"] UTF8String]);
            out[i].minimized = [e[@"minimized"] intValue];
            out[i].onScreen  = [e[@"onScreen"] intValue];
            out[i].zOrder    = [e[@"zOrder"] intValue];
        }
        *out_count = (int)result.count;
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
@end
@implementation GFEntry @end

@interface GFPanelView : NSView
@property (nonatomic, assign) NSInteger selected;
@property (nonatomic, strong) NSArray<GFEntry *> *entries;
@property (nonatomic, strong) NSTrackingArea *trackingArea;
@end

// Layout values. Kept as a single struct so drawing and hit-testing agree.
typedef struct {
    CGFloat margin, gap, titleH;
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
    CGFloat margin = 24, gap = 14, titleH = 22;
    CGFloat tileW = 240;
    CGFloat tileH = tileW * 0.65;
    CGFloat cellH = tileH + titleH + 4;
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
    L.cols = gf_pickCols(n);
    NSInteger rows = (n + L.cols - 1) / L.cols;

    CGFloat availW = b.size.width  - 2*L.margin;
    CGFloat availH = b.size.height - 2*L.margin;

    // tileW from each constraint; pick the smaller so every row fits and
    // nothing clips off the bottom of a clamped panel. tileH = tileW * 0.65.
    CGFloat tileWByWidth  = (availW - L.gap*(L.cols-1)) / L.cols;
    CGFloat innerCellH    = (availH - L.gap*(rows-1)) / rows;
    CGFloat tileWByHeight = (innerCellH - L.titleH - 4) / 0.65;
    L.tileW = MIN(tileWByWidth, tileWByHeight);
    if (L.tileW < 60) L.tileW = 60;
    L.tileH = L.tileW * 0.65;
    L.cellH = L.tileH + L.titleH + 4;

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
                      r.size.width, r.size.height + L.titleH + 2);
}

- (NSInteger)indexAtPoint:(NSPoint)p {
    NSInteger n = self.entries.count;
    if (n == 0) return -1;
    gf_layout_t L = [self layoutForCount:n];
    for (NSInteger i = 0; i < n; i++) {
        if (NSPointInRect(p, [self cellRectForIndex:i layout:L])) return i;
    }
    return -1;
}

- (void)drawRect:(NSRect)dirty {
    NSRect b = self.bounds;
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:b xRadius:14 yRadius:14];
    [[[NSColor windowBackgroundColor] colorWithAlphaComponent:0.92] setFill];
    [bg fill];

    NSInteger n = self.entries.count;
    if (n == 0) return;
    gf_layout_t L = [self layoutForCount:n];

    NSMutableParagraphStyle *para = [NSMutableParagraphStyle new];
    para.lineBreakMode = NSLineBreakByTruncatingTail;
    para.alignment = NSTextAlignmentCenter;
    NSDictionary *titleAttrs = @{
        NSFontAttributeName:            [NSFont systemFontOfSize:12],
        NSForegroundColorAttributeName: [NSColor labelColor],
        NSParagraphStyleAttributeName:  para,
    };

    for (NSInteger i = 0; i < n; i++) {
        NSRect imgR  = [self imageRectForIndex:i layout:L];
        NSRect textR = NSMakeRect(imgR.origin.x, imgR.origin.y - L.titleH - 2,
                                  imgR.size.width, L.titleH);

        if (i == self.selected) {
            NSRect hi = NSInsetRect(imgR, -6, -6);
            hi.size.height += L.titleH + 8;
            hi.origin.y -= L.titleH + 2;
            NSBezierPath *h = [NSBezierPath bezierPathWithRoundedRect:hi xRadius:10 yRadius:10];
            [[[NSColor controlAccentColor] colorWithAlphaComponent:0.55] setFill];
            [h fill];
        }

        GFEntry *e = self.entries[i];
        if (e.image) {
            NSSize is = e.image.size;
            NSSize ds;
            if (e.thumbLoaded) {
                // Live thumbnail: scale to fit the tile.
                CGFloat scale = MIN(imgR.size.width/is.width, imgR.size.height/is.height);
                ds = NSMakeSize(is.width*scale, is.height*scale);
            } else {
                // App icon (minimized window, or not-yet-captured). NSImage
                // picks the right rep when we ask for 64x64. Shrink if the
                // tile is tighter than that.
                CGFloat side = MIN(64.0, MIN(imgR.size.width, imgR.size.height) - 8);
                if (side < 16) side = 16;
                ds = NSMakeSize(side, side);
            }
            NSRect dr = NSMakeRect(imgR.origin.x + (imgR.size.width - ds.width)/2,
                                   imgR.origin.y + (imgR.size.height - ds.height)/2,
                                   ds.width, ds.height);
            [e.image drawInRect:dr fromRect:NSZeroRect
                      operation:NSCompositingOperationSourceOver fraction:1.0];
            if (e.minimized) {
                NSDictionary *bAttrs = @{
                    NSFontAttributeName: [NSFont boldSystemFontOfSize:10],
                    NSForegroundColorAttributeName: [NSColor secondaryLabelColor],
                };
                [@"minimized" drawAtPoint:NSMakePoint(imgR.origin.x+4, imgR.origin.y+4)
                           withAttributes:bAttrs];
            }
        }

        NSString *label = e.title.length > 0 ? e.title : e.appName;
        [label drawInRect:textR withAttributes:titleAttrs];
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
    NSInteger idx = [self indexAtPoint:p];
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
    void         *axRef;     // not retained here (Go owns)
    unsigned int  windowID;
    int           minimized;
    int           pid;
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
                      int minimized, int pid) {
    gf_pd_t *d = (gf_pd_t *)data;
    d->entries[idx].title     = strdup(title ?: "");
    d->entries[idx].appName   = strdup(appName ?: "");
    d->entries[idx].axRef     = axRef;
    d->entries[idx].windowID  = windowID;
    d->entries[idx].minimized = minimized;
    d->entries[idx].pid       = pid;
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

void gf_showPanel(void *data, int selected) {
    gf_pd_t *d = (gf_pd_t *)data;
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            ensurePanel();

            NSMutableArray<GFEntry *> *items = [NSMutableArray arrayWithCapacity:d->count];
            for (int i = 0; i < d->count; i++) {
                gf_pe_t *e = &d->entries[i];
                GFEntry *ge = [GFEntry new];
                ge.title    = [NSString stringWithUTF8String:e->title];
                ge.appName  = [NSString stringWithUTF8String:e->appName];
                ge.windowID = e->windowID;
                ge.pid      = e->pid;
                ge.minimized = e->minimized != 0;

                // Cache hit? Display instantly without any background work.
                NSImage *cached = nil;
                if (!ge.minimized && e->windowID != 0) {
                    cached = gThumbCache[@(e->windowID)];
                }
                if (cached) {
                    ge.image = cached;
                    ge.thumbLoaded = YES;
                    // Bump LRU (this counts as a use).
                    NSNumber *key = @(e->windowID);
                    [gThumbLRU removeObject:key];
                    [gThumbLRU addObject:key];
                } else {
                    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:(pid_t)e->pid];
                    ge.image = app.icon;
                }
                [items addObject:ge];
            }
            gPanelView.entries = items;
            gPanelView.selected = selected;

            // Size the panel to the content, clamped to the screen under the cursor.
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

            // Fill in cache misses, and refresh stale cached entries, in the
            // background. Each gf_captureAsync schedules its own work and
            // updates the live panel entry when it completes.
            NSDate *now = [NSDate date];
            for (GFEntry *e in items) {
                if (e.minimized || e.windowID == 0) continue;
                if (!e.thumbLoaded) {
                    gf_captureAsync(e.windowID);
                    continue;
                }
                NSDate *age = gThumbAge[@(e.windowID)];
                if (!age || [now timeIntervalSinceDate:age] > kThumbStaleAfter) {
                    gf_captureAsync(e.windowID);
                }
            }

            freePanelData(d);
        }
    });
}

void gf_updateSelection(int selected) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gPanelView) return;
        gPanelView.selected = selected;
        [gPanelView setNeedsDisplay:YES];
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
    if (!axRefPtr) return;
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
- (void)quit:(id)sender;
@end

@implementation GFStatusHandler
- (void)showGrid:(id)sender {
    // If the grid is somehow already up, close it first so this acts as a
    // clean re-open rather than triggering a cycle.
    if (atomic_load(&gActive)) gfOnCancel();
    gfOnHotkey(0, 0);
}
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
