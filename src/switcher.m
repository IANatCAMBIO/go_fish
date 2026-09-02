// switcher.m — the switcher state machine (ported from switcher.go).
//
// Owns the window list for the current activation, the selected index, and
// the open/closed flag. The event tap (Cmd+Tab / Cmd+` / Esc / flags-changed)
// and the panel's mouse handlers call the gfOn* / gfSetSelection functions
// declared in switcher.h; those drive the panel through the gf_* functions
// implemented in cocoa.m.
//
// Threading: every entry point runs on the main thread, but we hold gSwMu
// across each one anyway — it's the contract the Go original kept, and it's
// free under no contention. None of the gf_* calls re-enter the switcher, so
// there's no recursion on the lock.
//
// Opening the switcher is the one two-step operation. gfOnHotkey starts the
// window snapshot and returns; the list arrives later, on the main thread, via
// snapshotArrived. gSwOpen is false for that interval, so the pending-state
// block below exists to hold the events that land inside it. gfOnHotkey drops
// the lock before starting the snapshot, so the completion never contends with
// the call that scheduled it.

#include "cocoa.h"
#include "switcher.h"

#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

// =========================================================================
// State (guarded by gSwMu)
// =========================================================================

static pthread_mutex_t gSwMu = PTHREAD_MUTEX_INITIALIZER;

// The window list for the live activation. We hold onto the gf_window_t array
// gf_enumerateWindows hands back (sorted by zOrder) rather than copying it
// into a parallel struct — it already carries everything the switcher needs
// (axRef, pid, windowID, title, appName, minimized, unresponsive). We own its
// malloc'd title/appName strings and its retained axRefs until tearDown.
static gf_window_t *gSwList     = NULL;
static int          gSwCount    = 0;
static int          gSwSelected = 0;
static bool         gSwOpen     = false;   // panel is up (mirrors cocoa's gActive)

// Pending-snapshot state. Enumeration no longer blocks the main thread, so
// there is now a window between the opening hotkey press and the list arriving
// in which the switcher is neither closed nor open. Events that land in it must
// be remembered rather than dropped: before the split they could not occur at
// all, because gfOnHotkey did not return until gSwOpen was true.
static bool         gSwPending   = false;  // snapshot in flight
static unsigned long long gSwGen = 0;      // bumped to abandon an in-flight snapshot
static int          gSwPendAdv   = 0;      // net Tab / Shift+Tab presses while pending
static bool         gSwPendCommit = false; // hotkey released while pending

// =========================================================================
// Helpers (caller holds gSwMu)
// =========================================================================

// Ascending by zOrder — frontmost (smallest) first. zOrder values are unique
// per entry (gf_enumerateWindows increments a counter for every window), so a
// non-stable sort is fine.
static int cmpZOrder(const void *a, const void *b) {
    int za = ((const gf_window_t *)a)->zOrder;
    int zb = ((const gf_window_t *)b)->zOrder;
    return (za > zb) - (za < zb);
}

// Rank of the groups that are pinned to the end of the alphabetical grid,
// ahead of any name comparison. Minimized windows join them only while "Show
// minimized windows last in the grid" is enabled — the MRU comparator gets
// that behaviour for free from the zOrder bands gf_enumerateWindows assigns,
// but zOrder is exactly what this comparator does not look at, so the
// preference has to be read directly or it is silently ignored here.
static int appSortRank(const gf_window_t *w) {
    if (w->unresponsive) return 3;
    if (w->windowless)   return 2;
    if (w->minimized && gf_getMinimizedLast()) return 1;
    return 0;
}

// Alphabetical by app name (case-insensitive), then window title within each
// app. Pinned-to-the-end groups (see appSortRank) come after everything named,
// in the order minimized, windowless, unresponsive.
static int cmpAppName(const void *a, const void *b) {
    const gf_window_t *wa = (const gf_window_t *)a;
    const gf_window_t *wb = (const gf_window_t *)b;
    int rankA = appSortRank(wa), rankB = appSortRank(wb);
    if (rankA != rankB) return rankA - rankB;
    int appCmp = strcasecmp(wa->appName ? wa->appName : "", wb->appName ? wb->appName : "");
    if (appCmp != 0) return appCmp;
    return strcasecmp(wa->title ? wa->title : "", wb->title ? wb->title : "");
}

// Build the C panel-data blob from the current list. gf_showPanel /
// gf_updatePanelEntries take ownership and free it. gf_setPanelEntry strdup's
// the strings, so passing our owned pointers is safe.
static void *buildPanelData(void) {
    void *data = gf_newPanelData(gSwCount);
    for (int i = 0; i < gSwCount; i++) {
        gf_window_t *w = &gSwList[i];
        gf_setPanelEntry(data, i, w->title, w->appName, w->axRef, w->windowID,
                         w->minimized, w->pid, w->unresponsive, w->windowless);
    }
    return data;
}

static void showPanel(void) {
    if (gSwCount == 0) return;
    gf_showPanel(buildPanelData(), gSwSelected);
}

// In-place entry refresh without resizing/recentering — used after closing a
// window so the grid doesn't jump.
static void refreshPanel(void) {
    if (gSwCount == 0) return;
    gf_updatePanelEntries(buildPanelData(), gSwSelected);
}

// Release a window list handed back by enumeration: the retained AX refs and
// the malloc'd strings, then the array itself. A NULL axRef (unresponsive or
// windowless placeholder, or an entry whose ownership was transferred away on
// commit) is skipped.
static void freeWindowList(gf_window_t *list, int count) {
    if (!list) return;
    for (int i = 0; i < count; i++) {
        free(list[i].title);
        free(list[i].appName);
        if (list[i].axRef) gf_release(list[i].axRef);
    }
    free(list);
}

// Release the live list and clear state. The chosen window's axRef (on commit)
// is zeroed by the caller beforehand so it survives into gf_activateWindow,
// which releases it later.
static void tearDown(void) {
    gf_hidePanel();
    freeWindowList(gSwList, gSwCount);
    gSwList  = NULL;
    gSwCount = 0;
    gSwOpen  = false;
}

// Activate the selected window and close the switcher. Caller holds gSwMu and
// has checked gSwOpen.
static void commitSelection(void) {
    // Copy the chosen entry, then zero its axRef in the list so tearDown
    // doesn't release it — ownership transfers to gf_activateWindow, which
    // CFReleases after activating. (tearDown still frees the strings; that's
    // fine, gf_activateWindow doesn't touch them.)
    gf_window_t chosen = gSwList[gSwSelected];
    gSwList[gSwSelected].axRef = NULL;
    tearDown();
    gf_activateWindow(chosen.axRef, chosen.pid, chosen.minimized, chosen.windowless);
}

// Completion for gf_enumerateWindowsAsync — runs on the main thread and takes
// ownership of `list`. `gen` identifies the request; anything but the current
// generation was abandoned while in flight (cancelled, or superseded by a newer
// press) and is dropped rather than installed.
static void snapshotArrived(unsigned long long gen, gf_window_t *list, int count) {
    pthread_mutex_lock(&gSwMu);
    if (gen != gSwGen) {
        freeWindowList(list, count);
        pthread_mutex_unlock(&gSwMu);
        return;
    }
    gSwPending = false;
    int adv = gSwPendAdv, wantCommit = gSwPendCommit;
    gSwPendAdv = 0;
    gSwPendCommit = false;

    if (!list || count == 0) {
        freeWindowList(list, count);
        pthread_mutex_unlock(&gSwMu);
        return;
    }
    qsort(list, (size_t)count, sizeof(gf_window_t),
          gf_getSortMode() ? cmpAppName : cmpZOrder);
    gSwList  = list;
    gSwCount = count;
    gSwOpen  = true;

    // The opening press selects entry 1 (the previously-used window); any
    // further presses that arrived while the snapshot was in flight advance
    // from there, so a fast double-Tab lands where the user aimed.
    int base = (count > 1) ? 1 : 0;
    gSwSelected = ((base + adv) % count + count) % count;

    if (wantCommit) {
        // Hotkey released before the list arrived: a quick switch. Activate
        // without ever showing the grid — the same outcome the blocking path
        // produced via gf_showPanel's gQuickSwitch bail-out.
        commitSelection();
    } else {
        showPanel();
    }
    pthread_mutex_unlock(&gSwMu);
}

// =========================================================================
// Event entry points (switcher.h)
// =========================================================================

int gfOnHotkey(int shift, int scope) {
    pthread_mutex_lock(&gSwMu);
    if (!gSwOpen) {
        if (gSwPending) {
            // Snapshot still in flight. Bank the cycle instead of dropping the
            // press; snapshotArrived applies it to the initial selection.
            gSwPendAdv += shift ? -1 : 1;
            pthread_mutex_unlock(&gSwMu);
            return 1;
        }
        int filterPID = 0;
        if (scope == 1) {
            filterPID = gf_frontmostPID();
            if (filterPID == 0) {
                pthread_mutex_unlock(&gSwMu);
                return 0;
            }
        }
        // The opening press does not cycle — it selects entry 1 — so shift is
        // deliberately ignored here, matching the pre-async behaviour.
        gSwPending    = true;
        gSwPendAdv    = 0;
        gSwPendCommit = false;
        unsigned long long gen = ++gSwGen;
        pthread_mutex_unlock(&gSwMu);
        gf_enumerateWindowsAsync(filterPID, ^(gf_window_t *list, int count) {
            snapshotArrived(gen, list, count);
        });
        return 1;
    }
    if (shift) {
        gSwSelected = (gSwSelected - 1 + gSwCount) % gSwCount;
    } else {
        gSwSelected = (gSwSelected + 1) % gSwCount;
    }
    gf_updateSelection(gSwSelected);
    pthread_mutex_unlock(&gSwMu);
    return 1;
}

int gfOnCommit(void) {
    pthread_mutex_lock(&gSwMu);
    if (!gSwOpen) {
        if (gSwPending) {
            // Released before the list arrived. Defer rather than drop: while
            // enumeration blocked the main thread this ordering was impossible,
            // so returning 0 here would silently swallow every quick switch
            // that beat the snapshot.
            gSwPendCommit = true;
            pthread_mutex_unlock(&gSwMu);
            return 1;
        }
        pthread_mutex_unlock(&gSwMu);
        return 0;
    }
    commitSelection();
    pthread_mutex_unlock(&gSwMu);
    return 1;
}

void gfSetSelection(int idx) {
    pthread_mutex_lock(&gSwMu);
    if (!gSwOpen) {
        pthread_mutex_unlock(&gSwMu);
        return;
    }
    if (idx < 0 || idx >= gSwCount || idx == gSwSelected) {
        pthread_mutex_unlock(&gSwMu);
        return;
    }
    gSwSelected = idx;
    gf_updateSelection(gSwSelected);
    pthread_mutex_unlock(&gSwMu);
}

int gfOnCancel(void) {
    pthread_mutex_lock(&gSwMu);
    if (gSwPending) {
        // Abandon the in-flight snapshot: bumping the generation makes
        // snapshotArrived free the list instead of opening a grid the user
        // has already dismissed.
        gSwGen++;
        gSwPending    = false;
        gSwPendAdv    = 0;
        gSwPendCommit = false;
        pthread_mutex_unlock(&gSwMu);
        return 1;
    }
    if (!gSwOpen) {
        pthread_mutex_unlock(&gSwMu);
        return 0;
    }
    tearDown();
    pthread_mutex_unlock(&gSwMu);
    return 1;
}

void gfOnFocus(int idx) {
    pthread_mutex_lock(&gSwMu);
    if (!gSwOpen || idx < 0 || idx >= gSwCount) {
        pthread_mutex_unlock(&gSwMu);
        return;
    }
    int pid = gSwList[idx].pid;
    tearDown();
    gf_focusApp(pid);
    pthread_mutex_unlock(&gSwMu);
}

void gfToggleSort(void) {
    pthread_mutex_lock(&gSwMu);
    if (!gSwOpen || gSwCount == 0) {
        pthread_mutex_unlock(&gSwMu);
        return;
    }
    gf_toggleSortMode();
    qsort(gSwList, (size_t)gSwCount, sizeof(gf_window_t),
          gf_getSortMode() ? cmpAppName : cmpZOrder);
    gSwSelected = 0;
    refreshPanel();
    pthread_mutex_unlock(&gSwMu);
}

int gfOnClose(int idx) {
    pthread_mutex_lock(&gSwMu);
    if (!gSwOpen) {
        pthread_mutex_unlock(&gSwMu);
        return 0;
    }
    if (idx < 0 || idx >= gSwCount) {
        pthread_mutex_unlock(&gSwMu);
        return 0;
    }
    // Windowless app placeholders have no window to close, so "closing" one
    // quits the app (like Cmd+Q). Real windows fire the AX close button;
    // gf_closeWindow retains internally so it's safe to release our reference
    // immediately afterwards. Then free the strings and splice the entry out.
    if (gSwList[idx].windowless) {
        gf_quitApp(gSwList[idx].pid);
    } else {
        gf_closeWindow(gSwList[idx].axRef);
        gf_release(gSwList[idx].axRef);
    }
    free(gSwList[idx].title);
    free(gSwList[idx].appName);
    memmove(&gSwList[idx], &gSwList[idx + 1],
            (size_t)(gSwCount - idx - 1) * sizeof(gf_window_t));
    gSwCount--;

    if (gSwCount == 0) {
        tearDown();
        pthread_mutex_unlock(&gSwMu);
        return 1;
    }
    if (gSwSelected > idx) {
        gSwSelected--;
    } else if (gSwSelected == idx && gSwSelected >= gSwCount) {
        gSwSelected = gSwCount - 1;
    }
    refreshPanel();
    pthread_mutex_unlock(&gSwMu);
    return 1;
}
