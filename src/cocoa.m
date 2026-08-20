// cocoa.m — Cocoa side of go_fish.
//
// Responsibilities:
//   - NSApplication lifecycle (gf_run).
//   - Global CGEventTap intercepting Cmd+Tab / Cmd+` / flag changes / Escape.
//   - Window enumeration via the Accessibility API (covers minimized windows),
//     parallelized across apps via dispatch_apply so total latency scales with
//     max(per-app), not the sum across every running app.
//   - Thumbnail capture via CGWindowListCreateImage, resolved at runtime via
//     dlsym (the symbol was obsoleted in the macOS 15 SDK headers but still
//     ships in CoreGraphics). Future: migrate to ScreenCaptureKit.
//   - The borderless floating NSPanel that draws the grid.
//   - Window activation via AX (handles un-minimize + raise; the system
//     switches Spaces when the owning app is activated).
//   - Bulk window arrangement: gf_minimizeAll / gf_cascadeAll.
//   - Menu-bar status item + dropdown menu: Show Window Grid, Minimize All,
//     Cascade All, Start at boot, Secure Event Input detection, Quit.
//   - MRU tracker fed by NSWorkspaceDidActivateApplicationNotification plus
//     per-app AXObserver focused-window-changed callbacks.
//   - Login-item management for the "Start at boot" toggle: adds / removes
//     the running binary from the per-user Login Items list (System Settings
//     > General > Login Items) via the LSSharedFileList session list.
//     Effective on next login; we don't relaunch the current instance.
//   - Secure Event Input poller (1.5 s NSTimer) backing the SEI menu toggle.
//     When another app holds Secure Event Input, every third-party CGEventTap
//     is bypassed by macOS — so we paint a red-X overlay on the menu-bar icon
//     and update the tooltip to surface that go_fish is temporarily unavailable.

#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreServices/CoreServices.h>  // LSSharedFileList (Login Items)
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "cocoa.h"
#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// CGWindowListCreateImage was obsoleted in the macOS 15 SDK headers, but the
// symbol is still present in CoreGraphics at runtime. Load it dynamically so
// the binary builds against any SDK. (Future: migrate to ScreenCaptureKit.)
typedef CGImageRef (*gf_clci_t)(CGRect, uint32_t /*CGWindowListOption*/,
                                CGWindowID, uint32_t /*CGWindowImageOption*/);
static gf_clci_t gCGWindowListCreateImage = NULL;

// IsSecureEventInputEnabled lives in Carbon/HIToolbox. HIToolbox is loaded
// transitively by AppKit, so dlsym from RTLD_DEFAULT finds it without us
// linking Carbon explicitly. When secure input is on, session-level event
// taps cannot see keyboard events — Cmd+Tab bypasses go_fish.
typedef unsigned char (*gf_seien_t)(void);
static gf_seien_t gIsSecureEventInputEnabled = NULL;

static void gf_loadSymbols(void) {
    if (!gCGWindowListCreateImage) {
        gCGWindowListCreateImage = (gf_clci_t)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
    }
    if (!gIsSecureEventInputEnabled) {
        gIsSecureEventInputEnabled = (gf_seien_t)dlsym(RTLD_DEFAULT, "IsSecureEventInputEnabled");
    }
}

// Private API. Maps an AX window element to its CGWindowID. Stable for ~15 years.
extern AXError _AXUIElementGetWindow(AXUIElementRef element, CGWindowID *out);

// Switcher event entry points (defined in switcher.m). The event tap and the
// panel mouse handlers call these to drive selection / commit / cancel / close.
#include "switcher.h"

// =========================================================================
// State (main thread only, unless noted).
// =========================================================================

static atomic_int        gActive = 0;          // 1 when panel is up.
static CFMachPortRef     gEventTap = NULL;
static CFRunLoopSourceRef gEventTapSrc = NULL;

// 0 = Cmd+Tab (default), 1 = Ctrl+Tab, 2 = Option+Tab
static atomic_int gHotkeyModifier = 0;

// Quick-switch delay in milliseconds: 75, 100 (default), or 150.
static atomic_int gQuickSwitchDelayMs = 100;

// 1 = show the focus (eyeball) button on each grid tile (default on).
static atomic_int gShowFocusButton = 1;

// Set to 1 when the hotkey modifier is released before the panel has opened
// (i.e. gActive is still 0 at FlagsChanged time). gf_showPanel skips the grid
// and lets the already-queued gfOnCommit activate the window silently.
static atomic_int gQuickSwitch = 0;

// Eager-push guard: when gf_activateWindow pushes a winID to the MRU front
// before the OS activation completes, appActivated: may fire shortly after
// and overwrite it with a stale AX focused-window result. We record the
// pushed winID and timestamp here; appActivated: skips its push if the AX
// query returns a *different* window within the suppression window.
static CGWindowID     gLastEagerPushWinID  = 0;
static CFAbsoluteTime gLastEagerPushTime   = 0;
static const CFAbsoluteTime kEagerPushSuppressWindow = 0.5;

@class GFPanelView;
static NSPanel     *gPanel = nil;
static GFPanelView *gPanelView = nil;

@class GFStatusHandler;
static NSStatusItem    *gStatusItem    = nil;
static GFStatusHandler *gStatusHandler = nil;
static NSImage         *gIconNormal    = nil;  // template silhouette
static NSImage         *gIconSEI       = nil;  // composite with red X
static NSTimer         *gSEITimer      = nil;
static atomic_int       gSEIDetection  = 1;    // user preference
static atomic_int       gSEIActive     = 0;    // last observed state
static atomic_int       gShowWindowlessApps = 0; // user preference: surface
                                                 // running regular apps that
                                                 // have no windows as tiles.

// Sort mode for the grid thumbnail display. 0 = MRU (most-recently-used),
// 1 = alphabetical by application name.
static atomic_int gSortByApp = 0;

static atomic_int                                  gOverridesEnabled  = 0;
static NSArray<NSDictionary *>                    *gOverrideRules     = nil;
static NSMutableDictionary<NSString *, NSImage *> *gOverrideIconCache = nil;

@interface GFSettingsWindowController : NSObject
    <NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSWindow      *settingsWindow;
@property (nonatomic, strong) NSButton      *bootCheck;
@property (nonatomic, strong) NSButton      *windowlessCheck;
@property (nonatomic, strong) NSButton      *focusCheck;
@property (nonatomic, strong) NSPopUpButton *hotkeyPopup;
@property (nonatomic, strong) NSPopUpButton *delayPopup;
@property (nonatomic, strong) NSButton      *seiCheck;
// Override-rules UI
@property (nonatomic, strong) NSButton      *overrideEnableCheck;
@property (nonatomic, strong) NSScrollView  *overrideScrollView;
@property (nonatomic, strong) NSTableView   *overrideTable;
@property (nonatomic, strong) NSButton      *overrideRemoveBtn;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *overrideData;
@property (nonatomic, assign) BOOL           allowNextEdit;
- (void)showSettings:(id)sender;
@end
static GFSettingsWindowController *gSettingsController = nil;

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
// After the panel has been closed this long, drop the whole cache so an idle
// go_fish returns to its baseline footprint instead of pinning ~tens of MB of
// bitmaps. Cancelled whenever the panel reopens; quick re-opens stay warm.
static NSTimer                                    *gThumbPurgeTimer = nil;
static const NSTimeInterval                        kThumbIdlePurgeAfter = 45.0; // seconds

// Forward declarations — these are used by the panel UI, which is defined
// before the thumbnail-cache and MRU sections.
static void gf_pushMRU(CGWindowID winID);
static void gf_captureAsync(CGWindowID winID);
static void gf_scheduleThumbPurge(void);
static void gf_cancelThumbPurge(void);

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
        fprintf(stderr,
            "go_fish: event tap disabled by macOS (type=%u). "
            "Shortcuts won't fire until Accessibility permission is re-granted.\n"
            "  Fix: System Settings > Privacy & Security > Accessibility\n"
            "       Remove go_fish, re-add it, then quit and reopen go_fish.\n",
            type);
        if (gEventTap) CGEventTapEnable(gEventTap, true);
        return event;
    }

    CGEventFlags flags = CGEventGetFlags(event);
    CGEventFlags modMask;
    switch (atomic_load(&gHotkeyModifier)) {
        case 1:  modMask = kCGEventFlagMaskControl;   break;
        case 2:  modMask = kCGEventFlagMaskAlternate; break;
        default: modMask = kCGEventFlagMaskCommand;   break;
    }
    BOOL modDown = (flags & modMask) != 0;
    BOOL shift   = (flags & kCGEventFlagMaskShift) != 0;

    if (type == kCGEventKeyDown) {
        CGKeyCode key = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        if (modDown && key == 0x30 /* Tab */) {
            // Dispatch so the tap callback returns in < 1 µs. gfOnHotkey does
            // ~100 ms of AX window enumeration; calling it synchronously here
            // causes kCGEventTapDisabledByTimeout at the HID level and the
            // event slips through to the system switcher before we can consume it.
            atomic_store(&gQuickSwitch, 0); // reset — new key sequence starting
            int s = shift ? 1 : 0;
            dispatch_async(dispatch_get_main_queue(), ^{ gfOnHotkey(s, 0); });
            return NULL;
        }
        if (modDown && key == 0x32 /* ` (grave) */) {
            atomic_store(&gQuickSwitch, 0);
            int s = shift ? 1 : 0;
            dispatch_async(dispatch_get_main_queue(), ^{ gfOnHotkey(s, 1); });
            return NULL;
        }
        if (key == 0x35 /* Escape */ && atomic_load(&gActive)) {
            dispatch_async(dispatch_get_main_queue(), ^{ gfOnCancel(); });
            return NULL;
        }
    } else if (type == kCGEventFlagsChanged) {
        if (!modDown) {
            // If the modifier is released before the panel has opened (gActive
            // still 0), mark this as a quick switch. gf_showPanel will skip the
            // grid; the gfOnCommit dispatched below activates the window silently.
            if (!atomic_load(&gActive)) {
                atomic_store(&gQuickSwitch, 1);
            }
            dispatch_async(dispatch_get_main_queue(), ^{ gfOnCommit(); });
        }
    }
    return event;
}

static void installEventTap(void) {
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventFlagsChanged);
    // Prefer HID-level tap: it fires before the macOS system Cmd+Tab handler,
    // so we can intercept Cmd+Tab regardless of whether the system shortcut is
    // enabled in System Settings. Requires the same Accessibility permission
    // as the session-level tap; falls back to session-level if unavailable.
    gEventTap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap,
                                 kCGEventTapOptionDefault, mask, tapCallback, NULL);
    if (!gEventTap) {
        fprintf(stderr,
            "go_fish: HID event tap unavailable, falling back to session-level tap.\n"
            "  Cmd+Tab may be intercepted by the macOS switcher; if so, pick an\n"
            "  alternative hotkey via the go_fish menu bar icon → Switch hotkey.\n");
        gEventTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
                                     kCGEventTapOptionDefault, mask, tapCallback, NULL);
    }
    if (!gEventTap) {
        fprintf(stderr,
            "go_fish: FAILED to create event tap — keyboard shortcuts will not work.\n"
            "  Fix: System Settings > Privacy & Security > Accessibility\n"
            "       Remove go_fish from the list, re-add it, then relaunch.\n");
        return;
    }
    fprintf(stderr, "go_fish: event tap installed OK.\n");
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

// Pending entry: everything we collect per-window in the worker, minus the
// final zOrder. zOrder is assigned in the single-threaded merge phase so
// the global fallbackZ counter stays deterministic (same ordering as the
// pre-parallel implementation).
typedef struct {
    int            pid;
    AXUIElementRef axRef;       // retained +1; NULL for unresponsive placeholder
    CGWindowID     windowID;
    char          *title;       // malloc'd, ownership transfers to caller
    char          *appName;     // malloc'd, ownership transfers to caller
    int            minimized;
    int            onScreen;
    int            unresponsive;
    int            windowless;  // running regular app with no windows
    NSInteger      mruPos;      // NSNotFound if not in MRU
    int            cgOrder;     // -1 if not in cgIndex (off-screen / minimized)
} gf_pending_t;

typedef struct {
    gf_pending_t *items;
    int           count;
    int           cap;
} gf_slot_t;

// Fill an app's (empty) slot with a single windowless placeholder. Used when
// "Show apps without windows" is on and a responsive regular app turned up no
// standard windows. Mirrors the unresponsive placeholder, but with no
// "not responding" treatment — activating it just brings the app forward.
// Caller guarantees s->count is 0.
static void gf_addWindowlessSlot(gf_slot_t *s, NSRunningApplication *app, pid_t pid) {
    if (app.localizedName.length == 0) return;
    if (s->cap < 1) {
        free(s->items);  // free(NULL) is a no-op; also reclaims a calloc(0) stub
        s->items = (gf_pending_t *)calloc(1, sizeof(gf_pending_t));
        s->cap = 1;
    }
    gf_pending_t *p = &s->items[0];
    p->pid          = (int)pid;
    p->axRef        = NULL;
    p->windowID     = 0;
    p->title        = strdup([app.localizedName UTF8String]);
    p->appName      = strdup([app.localizedName UTF8String]);
    p->minimized    = 0;
    p->onScreen     = 0;
    p->unresponsive = 0;
    p->windowless   = 1;
    p->mruPos       = NSNotFound;
    p->cgOrder      = -1;
    s->count = 1;
}

gf_window_t *gf_enumerateWindows(int *out_count, int filterPID) {
    *out_count = 0;
    @autoreleasepool {
        // CGWindowID -> front-to-back-index map for sort + on-screen test.
        // Built once on the calling thread, then read concurrently from
        // workers. Copy to an immutable NSDictionary so concurrent reads
        // are documented-safe.
        NSMutableDictionary<NSNumber *, NSNumber *> *cgIndexM = [NSMutableDictionary dictionary];
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
                if (wid && !cgIndexM[wid]) cgIndexM[wid] = @((int)i);
            }
            CFRelease(cgList);
        }
        NSDictionary<NSNumber *, NSNumber *> *cgIndex = [cgIndexM copy];

        // Snapshot MRU into a winID -> index dict so workers can do O(1)
        // lookups without touching the mutable gMRU array (which the main
        // thread may rewrite via gf_pushMRU).
        NSDictionary<NSNumber *, NSNumber *> *mruIndex;
        {
            NSMutableDictionary<NSNumber *, NSNumber *> *m =
                [NSMutableDictionary dictionaryWithCapacity:gMRU.count];
            [gMRU enumerateObjectsUsingBlock:^(NSNumber *wid, NSUInteger idx, BOOL *_) {
                m[wid] = @(idx);
            }];
            mruIndex = [m copy];
        }

        // Filter the running-apps list down to what we'll actually query.
        NSArray<NSRunningApplication *> *apps =
            [[NSWorkspace sharedWorkspace] runningApplications];
        NSMutableArray<NSRunningApplication *> *targetsM =
            [NSMutableArray arrayWithCapacity:apps.count];
        for (NSRunningApplication *app in apps) {
            pid_t pid = app.processIdentifier;
            if (filterPID != 0) {
                if (pid != filterPID) continue;
            } else if (app.activationPolicy != NSApplicationActivationPolicyRegular) {
                continue;
            }
            [targetsM addObject:app];
        }
        NSArray<NSRunningApplication *> *targets = [targetsM copy];
        NSUInteger napps = targets.count;
        if (napps == 0) return NULL;

        // Per-app result slots. Each worker owns one slot — no sharing.
        gf_slot_t *slots = (gf_slot_t *)calloc(napps, sizeof(gf_slot_t));

        // Parallelize the per-app AX queries. AX calls on distinct
        // AXUIElementRefs are safe to call concurrently, and each worker
        // creates its own per-app ref. dispatch_apply blocks the caller
        // until all iterations finish, so slots[] is fully populated
        // before the merge.
        dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);
        dispatch_apply(napps, q, ^(size_t i) {
            @autoreleasepool {
                NSRunningApplication *app = targets[i];
                pid_t pid = app.processIdentifier;
                gf_slot_t *s = &slots[i];

                // Only in the all-apps grid (filterPID == 0) do we surface a
                // running regular app with no windows as a placeholder tile.
                BOOL wantWindowless =
                    (filterPID == 0) && atomic_load(&gShowWindowlessApps);

                AXUIElementRef axApp = AXUIElementCreateApplication(pid);
                if (!axApp) return;
                AXUIElementSetMessagingTimeout(axApp, kAXAppTimeout);

                CFArrayRef axWins = NULL;
                AXError err = AXUIElementCopyAttributeValue(
                    axApp, kAXWindowsAttribute, (CFTypeRef *)&axWins);

                if (err == kAXErrorCannotComplete) {
                    // Unresponsive: contribute a placeholder so the user
                    // can still see (and best-effort activate) the app.
                    if (app.localizedName.length == 0) {
                        CFRelease(axApp);
                        return;
                    }
                    s->items = (gf_pending_t *)calloc(1, sizeof(gf_pending_t));
                    s->cap = 1; s->count = 1;
                    gf_pending_t *p = &s->items[0];
                    p->pid          = (int)pid;
                    p->axRef        = NULL;
                    p->windowID     = 0;
                    p->title        = strdup([app.localizedName UTF8String]);
                    p->appName      = strdup([app.localizedName UTF8String]);
                    p->minimized    = 0;
                    p->onScreen     = 1;
                    p->unresponsive = 1;
                    p->mruPos       = NSNotFound;
                    p->cgOrder      = -1;
                    CFRelease(axApp);
                    return;
                }
                if (err != kAXErrorSuccess || !axWins) {
                    // Responsive, but reports no windows attribute at all.
                    if (wantWindowless) gf_addWindowlessSlot(s, app, pid);
                    if (axWins) CFRelease(axWins);
                    CFRelease(axApp);
                    return;
                }

                CFIndex wc = CFArrayGetCount(axWins);
                s->items = (gf_pending_t *)calloc((size_t)wc, sizeof(gf_pending_t));
                s->cap   = (int)wc;

                for (CFIndex j = 0; j < wc; j++) {
                    AXUIElementRef w = (AXUIElementRef)CFArrayGetValueAtIndex(axWins, j);

                    // Minimized state first: minimized windows always pass
                    // the subrole filter below, since some apps return them
                    // with a non-standard (or absent) subrole once minimized.
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

                    NSNumber *order  = winID ? cgIndex[@(winID)]  : nil;
                    NSNumber *mruIdx = winID ? mruIndex[@(winID)] : nil;
                    BOOL onScreen = (order != nil) && !minimized;

                    if (title.length == 0 && app.localizedName.length == 0) continue;

                    NSString *displayTitle = title.length > 0 ? title : app.localizedName;
                    NSString *displayApp   = app.localizedName ?: @"";

                    gf_pending_t *p = &s->items[s->count];
                    p->pid          = (int)pid;
                    p->axRef        = (AXUIElementRef)CFRetain(w);
                    p->windowID     = winID;
                    p->title        = strdup([displayTitle UTF8String]);
                    p->appName      = strdup([displayApp UTF8String]);
                    p->minimized    = minimized ? 1 : 0;
                    p->onScreen     = onScreen  ? 1 : 0;
                    p->unresponsive = 0;
                    p->windowless   = 0;
                    p->mruPos       = mruIdx ? (NSInteger)mruIdx.unsignedIntegerValue : NSNotFound;
                    p->cgOrder      = order ? order.intValue : -1;
                    s->count++;
                }
                CFRelease(axWins);
                // Had a windows attribute, but every window was filtered out
                // (non-standard subrole, no title). Treat as windowless.
                if (s->count == 0 && wantWindowless)
                    gf_addWindowlessSlot(s, app, pid);
                CFRelease(axApp);
            }
        });

        // Merge phase: walk slots in app order, assign zOrder using the
        // global fallbackZ counter. Same ordering as the pre-parallel impl.
        int cap = 0, count = 0, fallbackZ = 0;
        gf_window_t *out = NULL;
        gf_ensureCap(&out, &cap, 32);
        for (NSUInteger i = 0; i < napps; i++) {
            gf_slot_t *s = &slots[i];
            for (int j = 0; j < s->count; j++) {
                gf_pending_t *p = &s->items[j];
                gf_ensureCap(&out, &cap, count + 1);
                gf_window_t *e = &out[count];
                e->pid          = p->pid;
                e->axRef        = (void *)p->axRef;
                e->windowID     = p->windowID;
                e->title        = p->title;     // ownership moves to out
                e->appName      = p->appName;   // ownership moves to out
                e->minimized    = p->minimized;
                e->onScreen     = p->onScreen;
                e->unresponsive = p->unresponsive;
                e->windowless   = p->windowless;

                int zOrder;
                if (p->unresponsive) {
                    zOrder = 900000 + fallbackZ;
                } else if (p->windowless) {
                    // After all real windows, before unresponsive apps.
                    zOrder = 800000 + fallbackZ;
                } else if (p->mruPos != NSNotFound) {
                    zOrder = (int)p->mruPos;
                } else if (p->cgOrder >= 0) {
                    zOrder = 100000 + p->cgOrder;
                } else if (p->minimized) {
                    zOrder = 300000 + fallbackZ;
                } else {
                    zOrder = 200000 + fallbackZ;
                }
                e->zOrder = zOrder;
                fallbackZ++;
                count++;
            }
            free(s->items);
        }
        free(slots);

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
@property (nonatomic, assign) BOOL windowless;
@end
@implementation GFEntry @end

// Layout values. Kept as a single struct so drawing and hit-testing agree.
// appH is the band above the thumbnail that holds the application name;
// titleH is the band below the thumbnail that holds the window title.
typedef struct {
    CGFloat margin, gap, titleH, appH;
    NSInteger cols;
    CGFloat tileW, tileH, cellH;
    CGFloat topY;
} gf_layout_t;

@interface GFPanelView : NSView
@property (nonatomic, assign) NSInteger selected;
@property (nonatomic, strong) NSArray<GFEntry *> *entries;
@property (nonatomic, strong) NSTrackingArea *trackingArea;
// Layout frozen at show time. Column count and tile size stay fixed for the
// panel's lifetime so closing a thumbnail reflows the rest up-and-left without
// recentering or resizing. Reset on each show.
@property (nonatomic, assign) gf_layout_t baseLayout;
@property (nonatomic, assign) BOOL hasBaseLayout;
- (void)updateSelection:(NSInteger)idx;
@end

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

// Compute a layout sized for `n` tiles in the current bounds. Used to freeze
// the layout at show time; afterwards layoutForCount: returns the cached one.
- (gf_layout_t)computeLayoutForCount:(NSInteger)n {
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

    // Top-anchored: the first row's top sits at the top margin and rows grow
    // downward. Keeps the grid pinned up-and-left so closing tiles never
    // recenters the survivors.
    L.topY = b.size.height - L.margin;
    return L;
}

// The layout drawing and hit-testing should use. Once frozen at show time the
// cached layout is returned verbatim, so column count and tile size stay put
// as the entry count shrinks on close.
- (gf_layout_t)layoutForCount:(NSInteger)n {
    if (self.hasBaseLayout) return self.baseLayout;
    return [self computeLayoutForCount:n];
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
    CGFloat bandY = NSMaxY(r) + 2;
    CGFloat y     = bandY + (L.appH - d) / 2;
    return NSMakeRect(NSMinX(r), y, d, d);
}

// Focus-button rect for tile i — right side of the app-name band, mirroring close.
- (NSRect)focusRectForIndex:(NSInteger)i layout:(gf_layout_t)L {
    NSRect r = [self imageRectForIndex:i layout:L];
    CGFloat d = MIN(16.0, L.appH - 4.0);
    if (d < 10.0) d = 10.0;
    CGFloat bandY = NSMaxY(r) + 2;
    CGFloat y     = bandY + (L.appH - d) / 2;
    return NSMakeRect(NSMaxX(r) - d, y, d, d);
}

// Bottom-right sort toggle: two segments "Recent" | "By App".
// 58pt each with 1pt gap; 14pt from right edge (inside corner radius), 8pt from bottom.
static NSRect gf_sortToggleRect(NSRect bounds) {
    CGFloat segW = 58, h = 16, gap = 1;
    CGFloat totalW = segW * 2 + gap;
    return NSMakeRect(NSMaxX(bounds) - totalW - 14, 8, totalW, h);
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
        BOOL focusOn = atomic_load(&gShowFocusButton) != 0;
        // Symmetric padding: close button left, focus button right (or just margin
        // when hidden). Keeps the app name centered under the thumbnail in both states.
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

        // Close button: drawn for everything except unresponsive placeholders.
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

            // Focus button (⧉) — upper-right of the app-name band.
            if (focusOn) {
                NSRect focusR = [self focusRectForIndex:i layout:L];
                [[NSBezierPath bezierPathWithOvalInRect:focusR] fill];  // reuse dark fill set above
                NSDictionary *ga = @{
                    NSFontAttributeName: [NSFont systemFontOfSize:focusR.size.width * 0.62],
                    NSForegroundColorAttributeName: [NSColor colorWithWhite:1.0 alpha:0.95],
                };
                NSSize gs = [@"⧉" sizeWithAttributes:ga];
                [@"⧉" drawAtPoint:NSMakePoint(NSMidX(focusR) - gs.width  / 2,
                                               NSMidY(focusR) - gs.height / 2)
                    withAttributes:ga];
            }
        }
    }

    // Sort toggle — bottom-right corner, two segments: "Recent" | "By App".
    {
        NSRect tr = gf_sortToggleRect(b);
        CGFloat segW = (tr.size.width - 1) / 2;
        int sortMode = gf_getSortMode();

        // Outer pill background
        NSBezierPath *pill = [NSBezierPath bezierPathWithRoundedRect:tr
                                                             xRadius:tr.size.height / 2
                                                             yRadius:tr.size.height / 2];
        [[NSColor colorWithWhite:0.5 alpha:0.12] setFill];
        [pill fill];

        // Active segment highlight
        NSRect activeR = NSMakeRect(tr.origin.x + sortMode * (segW + 1),
                                    tr.origin.y, segW, tr.size.height);
        NSBezierPath *activePill = [NSBezierPath bezierPathWithRoundedRect:activeR
                                                                   xRadius:activeR.size.height / 2
                                                                   yRadius:activeR.size.height / 2];
        [[NSColor colorWithWhite:0.5 alpha:0.30] setFill];
        [activePill fill];

        NSString *segLabels[2] = {@"Recent", @"By App"};
        for (int s = 0; s < 2; s++) {
            NSRect segR = NSMakeRect(tr.origin.x + s * (segW + 1),
                                     tr.origin.y, segW, tr.size.height);
            BOOL isActive = (s == sortMode);
            NSDictionary *ta = @{
                NSFontAttributeName: [NSFont systemFontOfSize:10],
                NSForegroundColorAttributeName: isActive
                    ? [NSColor secondaryLabelColor]
                    : [NSColor tertiaryLabelColor],
            };
            NSSize ts = [segLabels[s] sizeWithAttributes:ta];
            [segLabels[s] drawAtPoint:NSMakePoint(NSMidX(segR) - ts.width  / 2,
                                                   NSMidY(segR) - ts.height / 2 + 0.5)
                       withAttributes:ta];
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
        // Drive selection through the switcher so state stays consistent;
        // it calls back into gf_updateSelection to redraw.
        gfSetSelection((int)idx);
    }
}

- (void)mouseDown:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];

    // Sort toggle hit-test: check before tiles so clicks on the toggle
    // don't fall through to whatever tile happens to be at that position.
    {
        NSRect tr = gf_sortToggleRect(self.bounds);
        if (NSPointInRect(p, tr)) {
            CGFloat segW = (tr.size.width - 1) / 2;
            NSRect seg1R = NSMakeRect(tr.origin.x + segW + 1, tr.origin.y, segW, tr.size.height);
            int clicked = NSPointInRect(p, seg1R) ? 1 : 0;
            if (clicked != gf_getSortMode()) {
                gfToggleSort();
            }
            return;
        }
    }

    NSInteger n = self.entries.count;
    if (n == 0) return;
    gf_layout_t L = [self layoutForCount:n];
    // Button hit-tests first (close and focus), before the tile-click fallthrough.
    // Unresponsive placeholders skip both buttons.
    for (NSInteger i = 0; i < n; i++) {
        GFEntry *ge = self.entries[i];
        if (ge.unresponsive) continue;
        if (NSPointInRect(p, [self closeRectForIndex:i layout:L])) {
            gfOnClose((int)i);
            return;
        }
        if (atomic_load(&gShowFocusButton) &&
            NSPointInRect(p, [self focusRectForIndex:i layout:L])) {
            gfOnFocus((int)i);
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
    int           windowless;
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
                      int minimized, int pid, int unresponsive, int windowless) {
    gf_pd_t *d = (gf_pd_t *)data;
    d->entries[idx].title        = strdup(title ?: "");
    d->entries[idx].appName      = strdup(appName ?: "");
    d->entries[idx].axRef        = axRef;
    d->entries[idx].windowID     = windowID;
    d->entries[idx].minimized    = minimized;
    d->entries[idx].pid          = pid;
    d->entries[idx].unresponsive = unresponsive;
    d->entries[idx].windowless   = windowless;
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

// Rebuild the override rule list and icon cache from NSUserDefaults.
// Must be called on the main thread. Sets gOverrideRules / gOverrideIconCache
// to nil when overrides are disabled, making gf_applyOverride a no-op.
static void gf_reloadOverrideRules(void) {
    if (!atomic_load(&gOverridesEnabled)) {
        gOverrideRules     = nil;
        gOverrideIconCache = nil;
        return;
    }
    NSArray *saved = [[NSUserDefaults standardUserDefaults]
        arrayForKey:@"OverrideRules"] ?: @[];
    NSMutableDictionary *cache = [NSMutableDictionary dictionary];
    for (NSDictionary *rule in saved) {
        NSString *path = rule[@"iconPath"];
        if (path.length > 0 && !cache[path]) {
            NSImage *img = [[NSImage alloc] initWithContentsOfFile:path];
            if (img) cache[path] = img;
        }
    }
    gOverrideRules     = [saved copy];
    gOverrideIconCache = cache;
}

// Apply the first matching override rule to ge. No-op (single nil check)
// when overrides are disabled. Matches against ge.title (the window title).
// Sets ge.appName and/or ge.image; sets ge.thumbLoaded=NO for icon overrides
// so the image renders centered at icon size rather than stretched.
static void gf_applyOverride(GFEntry *ge) {
    if (!gOverrideRules) return;
    for (NSDictionary *rule in gOverrideRules) {
        NSString *match = rule[@"matchString"];
        if (match.length == 0) continue;
        BOOL hit;
        if ([rule[@"matchType"] isEqualToString:@"exact"]) {
            hit = [ge.title isEqualToString:match];
        } else {
            hit = [ge.title rangeOfString:match
                                  options:NSCaseInsensitiveSearch].location != NSNotFound;
        }
        if (!hit) continue;
        NSString *name = rule[@"displayName"];
        if (name.length > 0) ge.appName = name;
        NSString *path = rule[@"iconPath"];
        if (path.length > 0) {
            NSImage *img = gOverrideIconCache[path];
            if (img) { ge.image = img; ge.thumbLoaded = NO; }
        }
        break;
    }
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
        ge.windowless   = e->windowless != 0;

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
        gf_applyOverride(ge);
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

// Main-thread only. Cache-purge bookkeeping; see kThumbIdlePurgeAfter.
static void gf_cancelThumbPurge(void) {
    if (gThumbPurgeTimer) {
        [gThumbPurgeTimer invalidate];
        gThumbPurgeTimer = nil;
    }
}

static void gf_scheduleThumbPurge(void) {
    gf_cancelThumbPurge();
    gThumbPurgeTimer = [NSTimer scheduledTimerWithTimeInterval:kThumbIdlePurgeAfter
                                                       repeats:NO
                                                         block:^(NSTimer *_t) {
        gThumbPurgeTimer = nil;
        // Re-check: a show may have raced in just before the timer fired.
        if (atomic_load(&gActive)) return;
        [gThumbCache removeAllObjects];
        [gThumbLRU   removeAllObjects];
        [gThumbAge   removeAllObjects];
    }];
}

void gf_showPanel(void *data, int selected) {
    gf_pd_t *d = (gf_pd_t *)data;
    // 100 ms delay before showing the panel so the run loop has time to drain
    // any pending HID events (modifier-up) before we commit to drawing the
    // grid. This is the "quick-switch window": if the user releases the hotkey
    // modifier within this period, gQuickSwitch is set to 1 and the block
    // below bails out instead of showing the panel. Without the delay the
    // dispatch queue can win the run loop race against the HID tap Mach port,
    // causing the panel to flash briefly even on a quick tap.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                (int64_t)atomic_load(&gQuickSwitchDelayMs) * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        // Quick-switch: hotkey released before panel opened. Skip the grid;
        // gfOnCommit is already queued and will activate the window.
        if (atomic_load(&gQuickSwitch)) {
            atomic_store(&gQuickSwitch, 0);
            freePanelData(d);
            return;
        }
        @autoreleasepool {
            ensurePanel();
            // Keep the cache alive while the panel is in use.
            gf_cancelThumbPurge();

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

            // Freeze the layout for this activation now that the frame (and
            // thus the view bounds) is final. Subsequent closes keep these
            // column/tile dimensions, so survivors stay pinned up-and-left.
            gf_layout_t L = [gPanelView computeLayoutForCount:d->count];

            // Resize the panel to exactly fit the computed tiles. When the
            // preferred size is clamped to screen bounds the two constraints
            // (width vs. height) rarely match: the tighter one drives tileW
            // while the looser dimension has leftover whitespace. Computing
            // the exact extent from tileW/cellH and re-setting the frame
            // eliminates that gap. topY must track the new height.
            NSInteger rows = ((NSInteger)d->count + L.cols - 1) / L.cols;
            CGFloat exactW = 2*L.margin + L.cols*L.tileW + (L.cols-1)*L.gap;
            CGFloat exactH = 2*L.margin + rows*L.cellH  + (rows-1)*L.gap;
            L.topY = exactH - L.margin;
            gPanelView.baseLayout    = L;
            gPanelView.hasBaseLayout = YES;
            NSRect exactR = NSMakeRect(vf.origin.x + (vf.size.width  - exactW)/2,
                                       vf.origin.y + (vf.size.height - exactH)/2,
                                       exactW, exactH);
            [gPanel setFrame:exactR display:NO];

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
    void (^hide)(void) = ^{
        if (gPanelView) {
            // Drop NSImage refs immediately so their CGImage bitmaps can be
            // freed; on retina screens these add up fast (~800 KB each).
            for (GFEntry *e in gPanelView.entries) { e.image = nil; }
            gPanelView.entries = nil;
            // Drop the frozen layout so the next show recomputes from scratch.
            gPanelView.hasBaseLayout = NO;
            [gPanelView setNeedsDisplay:YES];
        }
        if (gPanel) [gPanel orderOut:nil];
        // Reclaim the thumbnail cache once the panel has stayed closed a while.
        gf_scheduleThumbPurge();
    };
    // When called from the main thread (e.g. a mouse-down handler) run the
    // hide immediately so the panel is gone before the cascade or focus work
    // dispatched right after us executes.  From any other thread, dispatch
    // async as before.
    if (NSThread.isMainThread) {
        hide();
    } else {
        dispatch_async(dispatch_get_main_queue(), hide);
    }
}

// =========================================================================
// Activation
// =========================================================================

// Sends the app at `pid` a reopen Apple event (kAEReopenApplication) — exactly
// what a Dock-icon click delivers. An app with no open windows responds by
// creating its default window; one that already has windows just comes forward.
static void gf_sendReopen(pid_t pid) {
    NSAppleEventDescriptor *target = [NSAppleEventDescriptor
        descriptorWithDescriptorType:typeKernelProcessID
                                bytes:&pid
                               length:sizeof(pid)];
    NSAppleEventDescriptor *event = [NSAppleEventDescriptor
        appleEventWithEventClass:kCoreEventClass
                         eventID:kAEReopenApplication
                targetDescriptor:target
                        returnID:kAutoGenerateReturnID
                   transactionID:kAnyTransactionID];
    [event sendEventWithOptions:NSAppleEventSendNoReply timeout:0 error:NULL];
}

void gf_activateWindow(void *axRefPtr, int pid, int minimized, int windowless) {
    // No AX ref: an unresponsive-app or windowless placeholder. Bring the app
    // forward, and for windowless apps also reopen so they surface a window.
    if (!axRefPtr) {
        if (pid <= 0) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            @autoreleasepool {
                NSRunningApplication *app = [NSRunningApplication
                    runningApplicationWithProcessIdentifier:(pid_t)pid];
                [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
                if (windowless) gf_sendReopen((pid_t)pid);
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
            // eagerly makes quick toggle behave correctly.
            // Record the push so appActivated: can detect stale AX queries.
            CGWindowID winID = 0;
            _AXUIElementGetWindow(w, &winID);
            if (winID != 0) {
                gLastEagerPushWinID = winID;
                gLastEagerPushTime  = CFAbsoluteTimeGetCurrent();
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

void gf_quitApp(int pid) {
    if (pid <= 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            NSRunningApplication *app = [NSRunningApplication
                runningApplicationWithProcessIdentifier:(pid_t)pid];
            [app terminate];
        }
    });
}

int gf_getSortMode(void) {
    return atomic_load(&gSortByApp);
}

int gf_toggleSortMode(void) {
    int next = atomic_load(&gSortByApp) ? 0 : 1;
    atomic_store(&gSortByApp, next);
    [[NSUserDefaults standardUserDefaults] setBool:(next ? YES : NO) forKey:@"SortByApp"];
    return next;
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
            // The AX-primary screen is the one whose AppKit origin is (0,0) —
            // not necessarily firstObject, especially after a monitor change.
            CGFloat primaryH = [NSScreen mainScreen].frame.size.height;
            for (NSScreen *ps in [NSScreen screens])
                if (ps.frame.origin.x == 0.0 && ps.frame.origin.y == 0.0)
                    { primaryH = ps.frame.size.height; break; }
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

            // Cascade is user-initiated and can afford to wait. Set a longer
            // AX timeout per app so that busy apps (e.g. Firefox rendering
            // a heavy page) don't time out on the resize call. The 0.1s
            // timeout from enumeration is too short when the app is under load.
            NSMutableDictionary<NSNumber *, NSValue *> *cascadeAxApps =
                [NSMutableDictionary dictionary];
            for (int i = 0; i < n; i++) {
                if (!w[i].axRef) continue;
                NSNumber *pidKey = @(w[i].pid);
                if (!cascadeAxApps[pidKey]) {
                    AXUIElementRef axApp =
                        AXUIElementCreateApplication((pid_t)w[i].pid);
                    if (axApp) {
                        AXUIElementSetMessagingTimeout(axApp, 2.0f);
                        cascadeAxApps[pidKey] =
                            [NSValue valueWithPointer:(void *)axApp];
                    }
                }
            }

            int moved = 0, resized = 0, skipped = 0, step = 0;
            // Iterate back-to-front: backmost window gets step 0 (NW), each
            // more-front window steps down-right. The frontmost window is
            // processed last so if AX writes raise the window, it naturally
            // ends up on top before the raise loop corrects z-order.
            for (int i = n - 1; i >= 0; i--) {
                AXUIElementRef ax = (AXUIElementRef)w[i].axRef;
                if (!ax) { skipped++; continue; }

                // Skip windows that are neither on the current screen nor
                // minimized. Background tabs (same-frame NSWindow behind the
                // frontmost tab) and windows on other Spaces both land here:
                // they have a valid axRef but onScreen=NO and minimized=NO.
                if (!w[i].minimized && !w[i].onScreen) { skipped++; continue; }

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
                        "go_fish cascade: skipping \"%s\" (%s) — position not settable (err=%d settable=%d)\n",
                        w[i].title ?: "", w[i].appName ?: "",
                        (int)serr, (int)settable);
                    skipped++;
                    continue;
                }

                // Resize BEFORE repositioning. A window that is oversized
                // (e.g. was maximised on a larger external monitor) causes
                // macOS to clamp the subsequent position set — keeping the
                // window on-screen at its large size — so step 0 never lands
                // at (axStartX, axStartY). Shrinking first avoids that clamp.
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
                                "go_fish cascade: resize rejected for \"%s\" (%s) — AXError=%d\n",
                                w[i].title ?: "", w[i].appName ?: "", (int)rerr);
                        }
                    }
                } else {
                    fprintf(stderr,
                        "go_fish cascade: size not settable for \"%s\" (%s) — err=%d settable=%d\n",
                        w[i].title ?: "", w[i].appName ?: "",
                        (int)szerr, (int)szSettable);
                }

                // step increments only for windows that are actually cascaded,
                // so gaps from skipped windows don't misalign the staircase.
                int s = step % maxStep;
                CGPoint pt = CGPointMake(axStartX + offset * s,
                                         axStartY + offset * s);
                AXValueRef ptVal = AXValueCreate(kAXValueCGPointType, &pt);
                if (!ptVal) { skipped++; continue; }
                AXError perr = AXUIElementSetAttributeValue(ax,
                    kAXPositionAttribute, ptVal);
                CFRelease(ptVal);
                if (perr != kAXErrorSuccess) {
                    fprintf(stderr,
                        "go_fish cascade: failed to move \"%s\" (%s) — AXError=%d\n",
                        w[i].title ?: "", w[i].appName ?: "", (int)perr);
                    skipped++;
                    continue;
                }
                step++;
                moved++;
            }
            fprintf(stderr,
                    "go_fish cascade: moved %d, resized %d, skipped %d of %d (target %.0fx%.0f)\n",
                    moved, resized, skipped, n, targetW, targetH);

            for (NSValue *val in cascadeAxApps.allValues) {
                AXUIElementRef axApp = (AXUIElementRef)val.pointerValue;
                CFRelease(axApp);
            }

            // Un-minimize, exit-fullscreen, and (on some apps) the AX
            // position write itself raise the affected window in the global
            // z-stack, breaking the assumption above that z-order survives
            // the cascade. Walk back-to-front and re-raise each window so the
            // staircase ends with the original frontmost on top.
            //
            // The raises must be paced: cross-app activations race in
            // WindowServer when fired in a tight loop, and the previous
            // dispatch_after-with-precomputed-delays approach was broken —
            // the move/resize loop above keeps the main queue busy past the
            // last computed fire time, so every queued block ran back-to-back
            // with no spacing once we returned. Chain instead: each step
            // schedules the next, so the gap is always honored.
            //
            // Per-step: nominate the target window as the app's main BEFORE
            // raising. kAXRaiseAction is unreliable on Electron/Chromium
            // (raises whatever the app already considers main, not the
            // element we passed) — kAXMainAttribute pins it explicitly.
            int raiseCount = 0;
            for (int i = 0; i < n; i++)
                if (w[i].axRef && (w[i].minimized || w[i].onScreen)) raiseCount++;
            if (raiseCount > 0) {
                typedef struct { void *axRef; pid_t pid; } gf_raise_item_t;
                gf_raise_item_t *items =
                    (gf_raise_item_t *)malloc(raiseCount * sizeof(gf_raise_item_t));
                int k = 0;
                for (int i = n - 1; i >= 0; i--) {  // back-to-front order
                    if (!w[i].axRef) continue;
                    if (!w[i].minimized && !w[i].onScreen) continue;
                    items[k].axRef = (void *)CFRetain((CFTypeRef)w[i].axRef);
                    items[k].pid   = (pid_t)w[i].pid;
                    k++;
                }
                __block int chainIdx = 0;
                __block void (^raiseNext)(void) = nil;
                raiseNext = ^{
                    if (chainIdx >= raiseCount) {
                        free(items);
                        raiseNext = nil;  // break the __block retain cycle
                        return;
                    }
                    int j = chainIdx++;
                    AXUIElementRef axRef = (AXUIElementRef)items[j].axRef;
                    pid_t pid = items[j].pid;
                    @autoreleasepool {
                        AXUIElementSetAttributeValue(axRef,
                            kAXMainAttribute, kCFBooleanTrue);
                        AXUIElementPerformAction(axRef, kAXRaiseAction);
                        NSRunningApplication *app = [NSRunningApplication
                            runningApplicationWithProcessIdentifier:pid];
                        [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
                        CFRelease(axRef);
                    }
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                 100 * NSEC_PER_MSEC),
                                   dispatch_get_main_queue(), raiseNext);
                };
                dispatch_async(dispatch_get_main_queue(), raiseNext);
            }

            for (int i = 0; i < n; i++) {
                free(w[i].title);
                free(w[i].appName);
                if (w[i].axRef) gf_release(w[i].axRef);
            }
            free(w);
        }
    });
}

// Minimize all windows except pid's, then cascade pid's windows and activate
// the app. Called from gfOnFocus when the user clicks the eyeball in the grid.
void gf_focusApp(int pid) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            int n = 0;
            gf_window_t *all = gf_enumerateWindows(&n, 0);

            // Screen + cascade parameters (matches gf_cascadeAll).
            NSPoint cursor = [NSEvent mouseLocation];
            NSScreen *screen = [NSScreen mainScreen];
            for (NSScreen *s in [NSScreen screens])
                if (NSPointInRect(cursor, s.frame)) { screen = s; break; }
            NSRect vf = screen.visibleFrame;
            CGFloat primaryH = [NSScreen mainScreen].frame.size.height;
            for (NSScreen *ps in [NSScreen screens])
                if (ps.frame.origin.x == 0.0 && ps.frame.origin.y == 0.0)
                    { primaryH = ps.frame.size.height; break; }
            CGFloat axStartX = vf.origin.x;
            CGFloat axStartY = primaryH - (vf.origin.y + vf.size.height);
            CGFloat offset  = 32.0;
            CGFloat budget  = MAX(vf.size.height - 300.0, offset * 2);
            int     maxStep = MAX(1, (int)(budget / offset));
            CGFloat targetW = MIN(MAX(vf.size.width  * 0.75, 480.0), 1600.0);
            CGFloat targetH = MIN(MAX(vf.size.height * 0.75, 320.0), 1000.0);

            if (all) {
                qsort(all, n, sizeof(gf_window_t), gf_cmpZOrder); // front-to-back

                // Longer timeout for cascade resize operations (same reason as
                // gf_cascadeAll: busy apps can't service AX in 100ms).
                AXUIElementRef focusAxApp =
                    AXUIElementCreateApplication((pid_t)pid);
                if (focusAxApp) {
                    AXUIElementSetMessagingTimeout(focusAxApp, 2.0f);
                    CFRelease(focusAxApp);
                }

                // Minimize every window NOT belonging to pid.
                for (int i = 0; i < n; i++) {
                    if (all[i].pid == pid || all[i].minimized || !all[i].axRef) continue;
                    AXUIElementSetAttributeValue((AXUIElementRef)all[i].axRef,
                        kAXMinimizedAttribute, kCFBooleanTrue);
                }

                // Cascade pid's windows back-to-front so the frontmost window
                // (i==0) lands at the deepest step and remains visually on top.
                int step = 0;
                for (int i = n - 1; i >= 0; i--) {
                    if (all[i].pid != pid || !all[i].axRef) continue;
                    if (!all[i].minimized && !all[i].onScreen) continue;
                    AXUIElementRef ax = (AXUIElementRef)all[i].axRef;

                    if (all[i].minimized)
                        AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute, kCFBooleanFalse);
                    if (gf_isFullScreen(ax))
                        AXUIElementSetAttributeValue(ax, CFSTR("AXFullScreen"), kCFBooleanFalse);

                    // Resize before repositioning (same reason as gf_cascadeAll:
                    // avoids macOS clamping the position of an oversized window).
                    Boolean szSettable = false;
                    if (AXUIElementIsAttributeSettable(ax, kAXSizeAttribute, &szSettable) == kAXErrorSuccess && szSettable) {
                        CGSize sz = CGSizeMake(targetW, targetH);
                        AXValueRef sv = AXValueCreate(kAXValueCGSizeType, &sz);
                        if (sv) { AXUIElementSetAttributeValue(ax, kAXSizeAttribute, sv); CFRelease(sv); }
                    }
                    Boolean settable = false;
                    if (AXUIElementIsAttributeSettable(ax, kAXPositionAttribute, &settable) == kAXErrorSuccess && settable) {
                        int s = step % maxStep;
                        CGPoint pt = CGPointMake(axStartX + offset * s, axStartY + offset * s);
                        AXValueRef pv = AXValueCreate(kAXValueCGPointType, &pt);
                        if (pv) { AXUIElementSetAttributeValue(ax, kAXPositionAttribute, pv); CFRelease(pv); }
                    }
                    step++;
                }

                for (int i = 0; i < n; i++) {
                    free(all[i].title);
                    free(all[i].appName);
                    if (all[i].axRef) gf_release(all[i].axRef);
                }
                free(all);
            }

            // Activate the app regardless of whether enumeration succeeded.
            NSRunningApplication *app = [NSRunningApplication
                runningApplicationWithProcessIdentifier:(pid_t)pid];
            [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
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
    // Matches the largest a tile is ever drawn: tileW caps at 240pt, i.e. 480px
    // on a 2x Retina display. Capturing larger just wastes cache memory.
    const size_t kMaxDim = 480;
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
    // If the user never opens the panel, don't pin the bootstrap thumbnails
    // forever — let the idle purge reclaim them.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!atomic_load(&gActive)) gf_scheduleThumbPurge();
    });
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

// Forward decl so appActivated: can request an immediate SEI re-check.
// Defined down with the rest of the SEI poller machinery.
static void gf_pollSEI(void);

@implementation GFMRUTracker

- (void)appActivated:(NSNotification *)note {
    NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
    if (!app) return;
    pid_t pid = app.processIdentifier;
    CGWindowID winID = gf_focusedWindowForPID(pid);
    if (winID != 0) {
        // Guard against stale AX focused-window data. When the switcher just
        // activated a window via gf_activateWindow, we eagerly pushed that
        // winID to the MRU front. The NSWorkspace notification fires shortly
        // after, but gf_focusedWindowForPID may still return the *old*
        // focused window if the app hasn't processed our AX attributes yet.
        // If we're within the suppression window and AX returned a *different*
        // window than what we pushed, trust our eager push over the stale query.
        BOOL withinSuppress =
            gLastEagerPushWinID != 0 &&
            (CFAbsoluteTimeGetCurrent() - gLastEagerPushTime) < kEagerPushSuppressWindow;
        if (!withinSuppress || winID == gLastEagerPushWinID) {
            gf_pushMRU(winID);
        }
        gf_captureAsync(winID);
    }
    gf_installObserverForPID(pid); // in case it's a freshly-regular app

    // App activation is the dominant trigger for Secure Event Input
    // state changes — most SEI-holding apps assert it as part of
    // becoming active (or release it on resign). Re-poll immediately
    // so the red-X overlay flips inside one runloop tick instead of
    // waiting up to the next gSEITimer fire.
    gf_pollSEI();
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
- (void)showSettings:(id)sender;
- (void)quit:(id)sender;
@end

static void gf_startSEITimer(void);
static void gf_stopSEITimer(void);
static void gf_applySEIState(BOOL active);

@implementation GFStatusHandler
- (void)showGrid:(id)sender {
    if (atomic_load(&gActive)) gfOnCancel();
    gfOnHotkey(0, 0);
}
- (void)minimizeAll:(id)sender { gf_minimizeAll(); }
- (void)cascadeAll:(id)sender  { gf_cascadeAll();  }
- (void)showSettings:(id)sender {
    [gSettingsController showSettings:nil];
}
- (void)quit:(id)sender {
    [NSApp terminate:nil];
}
@end

// =========================================================================
// Login-item management ("Start at boot")
// =========================================================================
//
// We add/remove go_fish from the per-user Login Items list — the same list
// System Settings > General > Login Items shows and the "+" button populates.
// This is the LSSharedFileList session list: deprecated since 10.11 but still
// a working programmatic path (SMAppService is the modern alternative). The
// build passes -Wno-deprecated-declarations so these calls compile clean.
//
// We register the *.app bundle* rather than the inner Mach-O executable.
// LaunchServices runs a .app directly at login, with no window. A bare Unix
// binary, by contrast, has no LaunchServices opener, so macOS hosts it in
// Terminal.app — that's the stray terminal window users saw before. When
// go_fish is run loose (development, before `make app`), there is no bundle
// to register and we fall back to the executable path so the toggle still
// functions, terminal window and all.

// Resolve the running binary's absolute path. _NSGetExecutablePath may
// return a path with .. or symlinks; realpath flattens it so the login item
// holds a stable, canonical reference.
static NSString *gf_currentExecutablePath(void) {
    char buf[PATH_MAX];
    uint32_t size = sizeof(buf);
    if (_NSGetExecutablePath(buf, &size) != 0) return nil;
    char resolved[PATH_MAX];
    if (realpath(buf, resolved) != NULL) {
        return [NSString stringWithUTF8String:resolved];
    }
    return [NSString stringWithUTF8String:buf];
}

// The path we actually register as a login item: the enclosing .app bundle
// when we're running from one, otherwise the bare executable. Detected
// structurally — an executable at <X>.app/Contents/MacOS/<exe> means the
// bundle root is <X>.app.
static NSString *gf_loginItemPath(void) {
    NSString *exe = gf_currentExecutablePath();
    if (exe.length == 0) return exe;
    NSString *macosDir  = [exe stringByDeletingLastPathComponent];        // .../Contents/MacOS
    NSString *contents  = [macosDir stringByDeletingLastPathComponent];   // .../Contents
    NSString *appRoot   = [contents stringByDeletingLastPathComponent];   // .../<X>.app
    if ([[macosDir lastPathComponent] isEqualToString:@"MacOS"] &&
        [[contents lastPathComponent] isEqualToString:@"Contents"] &&
        [[appRoot pathExtension] isEqualToString:@"app"]) {
        return appRoot;
    }
    return exe;
}

static NSURL *gf_loginItemURL(void) {
    NSString *p = gf_loginItemPath();
    if (p.length == 0) return nil;
    return [NSURL fileURLWithPath:p];
}

// Find the login-item entry whose resolved path equals targetPath. Returns a
// retained LSSharedFileListItemRef (caller CFReleases) or NULL. `list` is
// borrowed. We match on the resolved filesystem path rather than the item's
// display name so a stale entry pointing at a different binary location
// doesn't masquerade as ours.
static LSSharedFileListItemRef gf_copyLoginItemMatching(LSSharedFileListRef list,
                                                        NSString *targetPath) {
    UInt32 seed = 0;
    CFArrayRef items = LSSharedFileListCopySnapshot(list, &seed);
    if (!items) return NULL;
    LSSharedFileListItemRef match = NULL;
    for (CFIndex i = 0; i < CFArrayGetCount(items); i++) {
        LSSharedFileListItemRef item =
            (LSSharedFileListItemRef)CFArrayGetValueAtIndex(items, i);
        CFURLRef cfURL = LSSharedFileListItemCopyResolvedURL(
            item, kLSSharedFileListNoUserInteraction
                | kLSSharedFileListDoNotMountVolumes, NULL);
        if (!cfURL) continue;
        NSString *itemPath = [(__bridge_transfer NSURL *)cfURL path];
        if ([itemPath isEqualToString:targetPath]) {
            match = (LSSharedFileListItemRef)CFRetain(item);
            break;
        }
    }
    CFRelease(items);
    return match;
}

int gf_isLoginItemInstalled(void) {
    NSString *path = gf_loginItemPath();
    if (path.length == 0) return 0;
    LSSharedFileListRef list =
        LSSharedFileListCreate(NULL, kLSSharedFileListSessionLoginItems, NULL);
    if (!list) return 0;
    LSSharedFileListItemRef item = gf_copyLoginItemMatching(list, path);
    int found = item ? 1 : 0;
    if (item) CFRelease(item);
    CFRelease(list);
    return found;
}

int gf_installLoginItem(void) {
    NSURL *url = gf_loginItemURL();
    if (!url) {
        fprintf(stderr, "go_fish: could not determine path for login item\n");
        return -1;
    }
    LSSharedFileListRef list =
        LSSharedFileListCreate(NULL, kLSSharedFileListSessionLoginItems, NULL);
    if (!list) {
        fprintf(stderr, "go_fish: could not open the Login Items list\n");
        return -1;
    }
    // Idempotent: if our binary is already registered, treat as success.
    LSSharedFileListItemRef existing = gf_copyLoginItemMatching(list, url.path);
    if (existing) {
        CFRelease(existing);
        CFRelease(list);
        return 0;
    }
    LSSharedFileListItemRef added = LSSharedFileListInsertItemURL(
        list, kLSSharedFileListItemLast, NULL, NULL,
        (__bridge CFURLRef)url, NULL, NULL);
    int rc = added ? 0 : -1;
    if (added) CFRelease(added);
    CFRelease(list);
    if (rc == 0) {
        fprintf(stderr, "go_fish: added login item %s — takes effect on next login.\n",
                url.path.UTF8String);
    } else {
        fprintf(stderr, "go_fish: failed to add login item\n");
    }
    return rc;
}

int gf_uninstallLoginItem(void) {
    NSString *path = gf_loginItemPath();
    if (path.length == 0) return -1;
    LSSharedFileListRef list =
        LSSharedFileListCreate(NULL, kLSSharedFileListSessionLoginItems, NULL);
    if (!list) {
        fprintf(stderr, "go_fish: could not open the Login Items list\n");
        return -1;
    }
    LSSharedFileListItemRef item = gf_copyLoginItemMatching(list, path);
    int rc = 0;
    if (item) {
        OSStatus s = LSSharedFileListItemRemove(list, item);
        CFRelease(item);
        if (s != noErr) {
            fprintf(stderr, "go_fish: failed to remove login item (status %d)\n", (int)s);
            rc = -1;
        } else {
            fprintf(stderr, "go_fish: removed login item %s\n", path.UTF8String);
        }
    }
    // Not present == already uninstalled == success.
    CFRelease(list);
    return rc;
}

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

// Build a "go_fish unavailable" composite: the silhouette in the current
// appearance's label color, with a bright red X stroked on top. Non-template
// so the red stays red regardless of menu-bar appearance.
static NSImage *gf_makeSEIIcon(NSImage *base) {
    if (!base) return nil;
    NSSize sz = base.size;
    NSImage *out = [NSImage imageWithSize:sz flipped:NO drawingHandler:^BOOL(NSRect _r) {
        NSRect r = NSMakeRect(0, 0, sz.width, sz.height);
        // Draw the silhouette, then tint it to labelColor via sourceAtop so
        // the icon stays legible in both light and dark menu bars.
        [base drawInRect:r];
        [[NSColor labelColor] set];
        NSRectFillUsingOperation(r, NSCompositingOperationSourceAtop);

        // Red X overlay.
        CGFloat pad = sz.width * 0.18;
        CGFloat lw  = MAX(2.0, sz.width * 0.18);
        NSBezierPath *p = [NSBezierPath bezierPath];
        [p moveToPoint:NSMakePoint(pad, pad)];
        [p lineToPoint:NSMakePoint(sz.width - pad, sz.height - pad)];
        [p moveToPoint:NSMakePoint(sz.width - pad, pad)];
        [p lineToPoint:NSMakePoint(pad, sz.height - pad)];
        p.lineWidth    = lw;
        p.lineCapStyle = NSLineCapStyleRound;
        [[NSColor systemRedColor] setStroke];
        [p stroke];
        return YES;
    }];
    out.template = NO;
    return out;
}

// Swap the status-item icon + tooltip to reflect whether Secure Event Input
// is currently blocking go_fish.
static void gf_applySEIState(BOOL active) {
    atomic_store(&gSEIActive, active ? 1 : 0);
    if (!gStatusItem) return;
    if (active) {
        gStatusItem.button.image   = gIconSEI ?: gIconNormal;
        gStatusItem.button.toolTip = @"go_fish unavailable — Secure Event Input is active";
    } else {
        gStatusItem.button.image   = gIconNormal;
        gStatusItem.button.toolTip = @"go_fish";
    }
}

static void gf_pollSEI(void) {
    if (!atomic_load(&gSEIDetection)) return;
    if (!gIsSecureEventInputEnabled) return;
    BOOL nowActive = gIsSecureEventInputEnabled() ? YES : NO;
    BOOL wasActive = atomic_load(&gSEIActive) ? YES : NO;
    if (nowActive != wasActive) gf_applySEIState(nowActive);
}

static void gf_startSEITimer(void) {
    if (gSEITimer) return;
    if (!gIsSecureEventInputEnabled) return;
    // 500 ms covers the in-app cases that don't fire an activation event
    // (Terminal entering `sudo`, password field gaining focus). App-
    // activation triggers get near-instant feedback via the explicit
    // re-poll in GFMRUTracker.appActivated:. IsSecureEventInputEnabled
    // is a sub-millisecond syscall, so 2 Hz polling is free.
    // NSRunLoopCommonModes covers NSDefaultRunLoopMode + NSEventTrackingRunLoopMode
    // so the X appears/disappears while the user has the menu open.
    gSEITimer = [NSTimer timerWithTimeInterval:0.5
                                       repeats:YES
                                         block:^(NSTimer *_t) { gf_pollSEI(); }];
    [[NSRunLoop currentRunLoop] addTimer:gSEITimer forMode:NSRunLoopCommonModes];
    // Fire once immediately so initial state is accurate.
    gf_pollSEI();
}

static void gf_stopSEITimer(void) {
    if (!gSEITimer) return;
    [gSEITimer invalidate];
    gSEITimer = nil;
}

// =========================================================================
// Settings window
// =========================================================================

@implementation GFSettingsWindowController

// ---- Helpers ----

- (void)syncOverrideUIEnabled {
    BOOL on = (self.overrideEnableCheck.state == NSControlStateValueOn);
    self.overrideScrollView.alphaValue = on ? 1.0 : 0.4;
    self.overrideRemoveBtn.enabled     = on && (self.overrideTable.selectedRow >= 0);
    self.overrideTable.enabled         = on;
}

- (void)saveOverrideRules {
    [[NSUserDefaults standardUserDefaults]
        setObject:[self.overrideData copy] forKey:@"OverrideRules"];
    gf_reloadOverrideRules();
}

// ---- Public entry point ----

- (void)showSettings:(id)sender {
    if (!self.settingsWindow) [self buildWindow];

    self.bootCheck.state = gf_isLoginItemInstalled()
        ? NSControlStateValueOn : NSControlStateValueOff;
    self.windowlessCheck.state = atomic_load(&gShowWindowlessApps)
        ? NSControlStateValueOn : NSControlStateValueOff;
    self.focusCheck.state = atomic_load(&gShowFocusButton)
        ? NSControlStateValueOn : NSControlStateValueOff;
    self.seiCheck.state = atomic_load(&gSEIDetection)
        ? NSControlStateValueOn : NSControlStateValueOff;
    [self.hotkeyPopup selectItemAtIndex:atomic_load(&gHotkeyModifier)];
    int cd = atomic_load(&gQuickSwitchDelayMs);
    [self.delayPopup selectItemAtIndex:(cd == 75) ? 0 : (cd == 150) ? 2 : 1];

    BOOL ovOn = atomic_load(&gOverridesEnabled) ? YES : NO;
    self.overrideEnableCheck.state =
        ovOn ? NSControlStateValueOn : NSControlStateValueOff;
    NSArray *saved = [[NSUserDefaults standardUserDefaults]
        arrayForKey:@"OverrideRules"] ?: @[];
    self.overrideData = [NSMutableArray arrayWithCapacity:saved.count];
    for (NSDictionary *d in saved)
        [self.overrideData addObject:[d mutableCopy]];
    [self.overrideTable reloadData];
    [self syncOverrideUIEnabled];

    [self.settingsWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

// ---- Window construction ----

- (void)buildWindow {
    const CGFloat W      = 620;
    const CGFloat margin = 20;
    const CGFloat checkW = W - 2 * margin;
    const CGFloat labelW = 148;
    const CGFloat popupX = margin + labelW + 8;
    const CGFloat popupW = W - popupX - margin;

    CGFloat y = margin;

    CGFloat seiY        = y; y += 22 + 8;
    CGFloat diagLabelY  = y; y += 16 + 10;
    CGFloat sep3Y       = y; y += 1  + 12;

    CGFloat btnRowY     = y; y += 24 + 4;
    CGFloat tableY      = y; y += 140 + 6;
    CGFloat ovEnableY   = y; y += 22 + 6;
    CGFloat ovLabelY    = y; y += 16 + 10;
    CGFloat sep2Y       = y; y += 1  + 12;

    CGFloat delayY      = y; y += 24 + 8;
    CGFloat hotkeyY     = y; y += 24 + 8;
    CGFloat focusY      = y; y += 22 + 8;
    CGFloat windowlessY = y; y += 22 + 8;
    CGFloat behLabelY   = y; y += 16 + 10;
    CGFloat sep1Y       = y; y += 1  + 12;

    CGFloat bootY       = y; y += 22 + 8;
    CGFloat genLabelY   = y; y += 16 + margin;

    const CGFloat H = y;

    NSWindow *win = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, W, H)
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    win.title = @"go_fish Settings";
    win.delegate = self;
    [win center];
    win.releasedWhenClosed = NO;
    [[win standardWindowButton:NSWindowZoomButton] setHidden:YES];
    [[win standardWindowButton:NSWindowMiniaturizeButton] setHidden:YES];
    NSView *cv = win.contentView;

    void (^addSectionLabel)(NSString *, CGFloat) = ^(NSString *t, CGFloat ly) {
        NSTextField *f = [NSTextField labelWithString:t];
        f.font = [NSFont boldSystemFontOfSize:[NSFont smallSystemFontSize]];
        f.textColor = [NSColor secondaryLabelColor];
        f.frame = NSMakeRect(margin, ly, checkW, 16);
        [cv addSubview:f];
    };

    void (^addSeparator)(CGFloat) = ^(CGFloat sy) {
        NSBox *sep = [[NSBox alloc] initWithFrame:NSMakeRect(margin, sy, checkW, 1)];
        sep.boxType = NSBoxSeparator;
        [cv addSubview:sep];
    };

    NSButton *(^addCheck)(NSString *, CGFloat, SEL) =
        ^NSButton *(NSString *t, CGFloat cy, SEL sel) {
            NSButton *b = [NSButton checkboxWithTitle:t target:self action:sel];
            b.frame = NSMakeRect(margin, cy, checkW, 22);
            [cv addSubview:b];
            return b;
        };

    NSPopUpButton *(^addPopupRow)(NSString *, NSArray<NSString *> *, CGFloat, SEL) =
        ^NSPopUpButton *(NSString *lbl, NSArray<NSString *> *opts, CGFloat ry, SEL sel) {
            NSTextField *lf = [NSTextField labelWithString:lbl];
            lf.alignment = NSTextAlignmentRight;
            lf.frame = NSMakeRect(margin, ry + 4, labelW, 16);
            [cv addSubview:lf];
            NSPopUpButton *pb = [[NSPopUpButton alloc]
                initWithFrame:NSMakeRect(popupX, ry, popupW, 24) pullsDown:NO];
            for (NSString *s in opts) [pb addItemWithTitle:s];
            pb.target = self;
            pb.action = sel;
            [cv addSubview:pb];
            return pb;
        };

    // ---- GENERAL ----
    addSectionLabel(@"GENERAL", genLabelY);
    self.bootCheck = addCheck(@"Start at boot", bootY, @selector(toggleBoot:));
    addSeparator(sep1Y);

    // ---- BEHAVIOR ----
    addSectionLabel(@"BEHAVIOR", behLabelY);
    self.windowlessCheck = addCheck(@"Show apps without windows",
                                    windowlessY, @selector(toggleWindowless:));
    self.focusCheck = addCheck(@"Show focus button in grid",
                               focusY, @selector(toggleFocusButton:));
    self.hotkeyPopup = addPopupRow(@"Hotkey:",
        @[@"Cmd+Tab (default)", @"Ctrl+Tab", @"Option+Tab"],
        hotkeyY, @selector(changeHotkey:));
    self.delayPopup = addPopupRow(@"Quick switch delay:",
        @[@"75 ms", @"100 ms (default)", @"150 ms"],
        delayY, @selector(changeDelay:));
    addSeparator(sep2Y);

    // ---- OVERRIDES ----
    addSectionLabel(@"OVERRIDES", ovLabelY);
    self.overrideEnableCheck = addCheck(@"Enable window title overrides",
                                        ovEnableY, @selector(toggleOverridesEnabled:));

    NSScrollView *sv = [[NSScrollView alloc]
        initWithFrame:NSMakeRect(margin, tableY, checkW, 140)];
    sv.hasVerticalScroller = YES;
    sv.autohidesScrollers  = YES;
    sv.borderType          = NSBezelBorder;

    NSTableView *tv = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, checkW, 140)];
    tv.usesAlternatingRowBackgroundColors = YES;
    tv.rowHeight  = 20;
    tv.dataSource = self;
    tv.delegate   = self;
    tv.doubleAction = @selector(tableDoubleClicked:);
    tv.target       = self;
    // Last column auto-fills remaining width so the vertical scrollbar never clips columns.
    tv.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    tv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    CGFloat colWidths[] = {160, 90, 140, 0};
    NSString *colIDs[]    = {@"matchString", @"matchType", @"displayName", @"iconPath"};
    NSString *colTitles[] = {@"Match String", @"Match Type", @"New Process Name", @"New Icon (double-click)"};
    CGFloat usedW = colWidths[0] + colWidths[1] + colWidths[2];
    colWidths[3] = checkW - usedW - 3;
    if (colWidths[3] < 40) colWidths[3] = 40;

    for (int c = 0; c < 4; c++) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:colIDs[c]];
        col.title        = colTitles[c];
        col.width        = colWidths[c];
        col.minWidth     = 40;
        col.resizingMask = NSTableColumnUserResizingMask;
        if (c == 1) {
            NSPopUpButtonCell *pc = [[NSPopUpButtonCell alloc]
                initTextCell:@"" pullsDown:NO];
            [pc addItemWithTitle:@"Substring"];
            [pc addItemWithTitle:@"Exact"];
            pc.controlSize = NSControlSizeSmall;
            pc.font        = [NSFont systemFontOfSize:
                [NSFont systemFontSizeForControlSize:NSControlSizeSmall]];
            pc.bordered    = NO;
            col.dataCell   = pc;
        } else {
            NSTextFieldCell *tc = [[NSTextFieldCell alloc] initTextCell:@""];
            tc.editable      = (c != 3);
            tc.selectable    = (c != 3);
            tc.font          = [NSFont systemFontOfSize:
                [NSFont systemFontSizeForControlSize:NSControlSizeSmall]];
            tc.lineBreakMode = NSLineBreakByTruncatingTail;
            col.dataCell     = tc;
        }
        [tv addTableColumn:col];
    }

    sv.documentView = tv;
    [cv addSubview:sv];
    self.overrideScrollView = sv;
    self.overrideTable      = tv;

    CGFloat bx = margin;
    NSButton *addBtn = [[NSButton alloc] initWithFrame:NSMakeRect(bx, btnRowY, 24, 24)];
    addBtn.bezelStyle = NSBezelStyleSmallSquare;
    addBtn.title      = @"+";
    addBtn.target     = self;
    addBtn.action     = @selector(addOverrideRule:);
    [cv addSubview:addBtn]; bx += 24 + 4;

    self.overrideRemoveBtn = [[NSButton alloc] initWithFrame:NSMakeRect(bx, btnRowY, 24, 24)];
    self.overrideRemoveBtn.bezelStyle = NSBezelStyleSmallSquare;
    self.overrideRemoveBtn.title      = @"−";
    self.overrideRemoveBtn.target     = self;
    self.overrideRemoveBtn.action     = @selector(removeOverrideRule:);
    [cv addSubview:self.overrideRemoveBtn];

    addSeparator(sep3Y);

    // ---- DIAGNOSTICS ----
    addSectionLabel(@"DIAGNOSTICS", diagLabelY);
    self.seiCheck = addCheck(@"Secure Event Input detection",
                              seiY, @selector(toggleSEI:));

    self.settingsWindow = win;
}

// ---- NSTableViewDataSource ----

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv {
    return (NSInteger)self.overrideData.count;
}

- (id)tableView:(NSTableView *)tv
    objectValueForTableColumn:(NSTableColumn *)col
                          row:(NSInteger)row {
    NSMutableDictionary *rule = self.overrideData[(NSUInteger)row];
    NSString *ident = col.identifier;
    if ([ident isEqualToString:@"matchType"])
        return [rule[@"matchType"] isEqualToString:@"exact"] ? @1 : @0;
    if ([ident isEqualToString:@"iconPath"]) {
        NSString *path = rule[@"iconPath"] ?: @"";
        return path.length > 0 ? path.lastPathComponent : @"";
    }
    return rule[ident] ?: @"";
}

- (void)tableView:(NSTableView *)tv
   setObjectValue:(id)obj
   forTableColumn:(NSTableColumn *)col
              row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.overrideData.count) return;
    NSMutableDictionary *rule = self.overrideData[(NSUInteger)row];
    NSString *ident = col.identifier;
    if ([ident isEqualToString:@"matchType"]) {
        rule[@"matchType"] = ([obj integerValue] == 1) ? @"exact" : @"substring";
    } else if (![ident isEqualToString:@"iconPath"]) {
        rule[ident] = obj ?: @"";
    }
    [self saveOverrideRules];
}

// ---- NSTableViewDelegate ----

- (BOOL)tableView:(NSTableView *)tv shouldEditTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    if ([col.identifier isEqualToString:@"iconPath"]) return NO;
    if ([col.identifier isEqualToString:@"matchType"]) return YES;
    // Text columns only edit when explicitly triggered from double-click.
    if (self.allowNextEdit) { self.allowNextEdit = NO; return YES; }
    return NO;
}

- (void)tableViewSelectionDidChange:(NSNotification *)note {
    BOOL on  = (self.overrideEnableCheck.state == NSControlStateValueOn);
    BOOL sel = (self.overrideTable.selectedRow >= 0);
    self.overrideRemoveBtn.enabled = on && sel;
}

// ---- Override CRUD ----

- (void)toggleOverridesEnabled:(NSButton *)sender {
    int next = (sender.state == NSControlStateValueOn) ? 1 : 0;
    atomic_store(&gOverridesEnabled, next);
    [[NSUserDefaults standardUserDefaults] setBool:(next ? YES : NO)
                                            forKey:@"OverridesEnabled"];
    gf_reloadOverrideRules();
    [self syncOverrideUIEnabled];
}

- (void)addOverrideRule:(id)sender {
    [self.overrideData addObject:[@{
        @"matchString": @"",
        @"matchType":   @"substring",
        @"displayName": @"",
        @"iconPath":    @""
    } mutableCopy]];
    [self.overrideTable reloadData];
    NSInteger newRow = (NSInteger)self.overrideData.count - 1;
    [self.overrideTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)newRow]
                    byExtendingSelection:NO];
    [self.overrideTable scrollRowToVisible:newRow];
    [self saveOverrideRules];
    [self syncOverrideUIEnabled];
}

- (void)removeOverrideRule:(id)sender {
    NSInteger row = self.overrideTable.selectedRow;
    if (row < 0 || row >= (NSInteger)self.overrideData.count) return;
    [self.overrideData removeObjectAtIndex:(NSUInteger)row];
    [self.overrideTable reloadData];
    [self saveOverrideRules];
    [self syncOverrideUIEnabled];
}

- (void)tableDoubleClicked:(NSTableView *)tv {
    NSInteger col = tv.clickedColumn;
    NSInteger row = tv.clickedRow;
    if (col < 0 || row < 0) return;
    if (self.overrideEnableCheck.state != NSControlStateValueOn) return;
    NSString *ident = [tv.tableColumns[col] identifier];
    if ([ident isEqualToString:@"iconPath"]) {
        [self setOverrideIcon:tv];
    } else if (![ident isEqualToString:@"matchType"]) {
        // Text column — open the cell editor.
        self.allowNextEdit = YES;
        [tv editColumn:col row:row withEvent:nil select:YES];
    }
    // matchType: popup cell handles its own click tracking; no action needed here.
}

- (void)setOverrideIcon:(id)sender {
    NSInteger row = self.overrideTable.selectedRow;
    if (row < 0 || row >= (NSInteger)self.overrideData.count) return;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = @"Choose Icon";
    panel.allowedFileTypes = @[@"icns", @"ico", @"png"];
    panel.allowsMultipleSelection = NO;
    panel.canChooseDirectories    = NO;
    [panel beginSheetModalForWindow:self.settingsWindow
                  completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK) return;
        NSString *path = panel.URL.path;
        if (!path) return;
        self.overrideData[(NSUInteger)row][@"iconPath"] = path;
        [self.overrideTable reloadData];
        [self saveOverrideRules];
    }];
}

// ---- Existing settings actions ----

- (void)toggleBoot:(NSButton *)sender {
    BOOL on = (sender.state == NSControlStateValueOn);
    int rc = on ? gf_installLoginItem() : gf_uninstallLoginItem();
    if (rc != 0) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = on ? @"Couldn't add go_fish to Login Items."
                           : @"Couldn't remove go_fish from Login Items.";
        a.informativeText = @"See the go_fish stderr log for details.";
        [a runModal];
    }
    sender.state = gf_isLoginItemInstalled()
        ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)toggleWindowless:(NSButton *)sender {
    int next = (sender.state == NSControlStateValueOn) ? 1 : 0;
    atomic_store(&gShowWindowlessApps, next);
    [[NSUserDefaults standardUserDefaults] setBool:(next ? YES : NO)
                                            forKey:@"ShowWindowlessApps"];
}

- (void)toggleFocusButton:(NSButton *)sender {
    int next = (sender.state == NSControlStateValueOn) ? 1 : 0;
    atomic_store(&gShowFocusButton, next);
    [[NSUserDefaults standardUserDefaults] setBool:(next ? YES : NO)
                                            forKey:@"ShowFocusButton"];
}

- (void)changeHotkey:(NSPopUpButton *)sender {
    int choice = (int)sender.indexOfSelectedItem;
    atomic_store(&gHotkeyModifier, choice);
    [[NSUserDefaults standardUserDefaults] setInteger:choice forKey:@"HotkeyModifier"];
}

- (void)changeDelay:(NSPopUpButton *)sender {
    int vals[] = {75, 100, 150};
    int ms = vals[(int)sender.indexOfSelectedItem];
    atomic_store(&gQuickSwitchDelayMs, ms);
    [[NSUserDefaults standardUserDefaults] setInteger:ms forKey:@"QuickSwitchDelayMs"];
}

- (void)toggleSEI:(NSButton *)sender {
    int next = (sender.state == NSControlStateValueOn) ? 1 : 0;
    atomic_store(&gSEIDetection, next);
    [[NSUserDefaults standardUserDefaults] setBool:(next ? YES : NO)
                                            forKey:@"SEIDetection"];
    if (next) {
        gf_startSEITimer();
    } else {
        gf_stopSEITimer();
        gf_applySEIState(NO);
    }
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    [sender orderOut:nil];
    return NO;
}

@end

static void installStatusItem(const void *iconBytes, int iconLen) {
    NSImage *icon = gf_makeMenuIcon(iconBytes, iconLen);
    gIconNormal    = icon;
    gIconSEI       = gf_makeSEIIcon(icon);
    gStatusHandler = [GFStatusHandler new];
    gStatusItem = [[NSStatusBar systemStatusBar]
        statusItemWithLength:NSVariableStatusItemLength];
    gStatusItem.button.image   = icon;
    gStatusItem.button.toolTip = @"go_fish";

    // Restore the user's preferences.
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults registerDefaults:@{@"SEIDetection": @YES,
                                 @"ShowWindowlessApps": @NO,
                                 @"ShowFocusButton": @YES,
                                 @"HotkeyModifier": @0,
                                 @"QuickSwitchDelayMs": @100,
                                 @"OverridesEnabled": @NO,
                                 @"OverrideRules": @[],
                                 @"SortByApp": @NO}];
    atomic_store(&gSEIDetection, [defaults boolForKey:@"SEIDetection"] ? 1 : 0);
    atomic_store(&gOverridesEnabled, [defaults boolForKey:@"OverridesEnabled"] ? 1 : 0);
    gf_reloadOverrideRules();
    atomic_store(&gShowWindowlessApps,
                 [defaults boolForKey:@"ShowWindowlessApps"] ? 1 : 0);
    atomic_store(&gShowFocusButton,
                 [defaults boolForKey:@"ShowFocusButton"] ? 1 : 0);
    atomic_store(&gHotkeyModifier, (int)[defaults integerForKey:@"HotkeyModifier"]);
    atomic_store(&gQuickSwitchDelayMs, (int)[defaults integerForKey:@"QuickSwitchDelayMs"]);
    atomic_store(&gSortByApp, [defaults boolForKey:@"SortByApp"] ? 1 : 0);

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

    gSettingsController = [GFSettingsWindowController new];
    NSMenuItem *settingsItem = [[NSMenuItem alloc] initWithTitle:@"Settings…"
                                                          action:@selector(showSettings:)
                                                   keyEquivalent:@","];
    settingsItem.target = gStatusHandler;
    [menu addItem:settingsItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit"
                                                      action:@selector(quit:)
                                               keyEquivalent:@"q"];
    quitItem.target = gStatusHandler;
    [menu addItem:quitItem];
    gStatusItem.menu = menu; // clicking the icon now pops this menu

    if (atomic_load(&gSEIDetection)) gf_startSEITimer();
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
