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

// Snapshot the current windows into gSwList, sorted by zOrder. filterPID == 0
// means all regular apps; otherwise only that pid's windows.
static void snapshotWindows(int filterPID) {
    int n = 0;
    gf_window_t *raw = gf_enumerateWindows(&n, filterPID);
    if (!raw || n == 0) {
        if (raw) free(raw);
        gSwList = NULL;
        gSwCount = 0;
        return;
    }
    qsort(raw, (size_t)n, sizeof(gf_window_t), cmpZOrder);
    gSwList  = raw;
    gSwCount = n;
}

// Release retained AX refs, free the malloc'd strings, and clear state. The
// chosen window's axRef (on commit) is zeroed by the caller beforehand so it
// survives into gf_activateWindow, which releases it later.
static void tearDown(void) {
    gf_hidePanel();
    for (int i = 0; i < gSwCount; i++) {
        free(gSwList[i].title);
        free(gSwList[i].appName);
        if (gSwList[i].axRef) gf_release(gSwList[i].axRef);
    }
    free(gSwList);
    gSwList  = NULL;
    gSwCount = 0;
    gSwOpen  = false;
}

// =========================================================================
// Event entry points (switcher.h)
// =========================================================================

int gfOnHotkey(int shift, int scope) {
    pthread_mutex_lock(&gSwMu);
    if (!gSwOpen) {
        int filterPID = 0;
        if (scope == 1) {
            filterPID = gf_frontmostPID();
            if (filterPID == 0) {
                pthread_mutex_unlock(&gSwMu);
                return 0;
            }
        }
        snapshotWindows(filterPID);
        if (gSwCount == 0) {
            pthread_mutex_unlock(&gSwMu);
            return 0;
        }
        gSwOpen = true;
        gSwSelected = (gSwCount > 1) ? 1 : 0;
        showPanel();
        pthread_mutex_unlock(&gSwMu);
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
        pthread_mutex_unlock(&gSwMu);
        return 0;
    }
    // Copy the chosen entry, then zero its axRef in the list so tearDown
    // doesn't release it — ownership transfers to gf_activateWindow, which
    // CFReleases after activating. (tearDown still frees the strings; that's
    // fine, gf_activateWindow doesn't touch them.)
    gf_window_t chosen = gSwList[gSwSelected];
    gSwList[gSwSelected].axRef = NULL;
    tearDown();
    gf_activateWindow(chosen.axRef, chosen.pid, chosen.minimized);
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
    if (!gSwOpen) {
        pthread_mutex_unlock(&gSwMu);
        return 0;
    }
    tearDown();
    pthread_mutex_unlock(&gSwMu);
    return 1;
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
