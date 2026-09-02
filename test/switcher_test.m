// switcher_test.m — event-ordering tests for the switcher state machine.
//
// Links the real src/switcher.m against stub gf_* backend functions, so the
// state machine can be driven through orderings that are hard to produce by
// hand on a live desktop. The stubs record what the switcher asked for and let
// the test decide when an in-flight window snapshot "arrives".
//
// The cases that matter are the ones that only became reachable when
// enumeration moved off the main thread: before that, gfOnHotkey did not return
// until the grid was open, so nothing could land between the two.
//
// Build and run: make test

#include "../src/cocoa.h"
#include "../src/switcher.h"

#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// =========================================================================
// Stub backend — records calls, never touches AX or the UI
// =========================================================================

static int   gShowPanelCalls    = 0;
static int   gShowPanelSelected = -1;
static int   gHidePanelCalls    = 0;
static int   gActivateCalls     = 0;
static int   gActivatedPID      = -1;
static int   gUpdateSelCalls    = 0;
static int   gLastUpdateSel     = -1;
static int   gReleaseCalls      = 0;

// The pending snapshot: gf_enumerateWindowsAsync parks its completion here
// instead of dispatching, so a test can interleave events before firing it.
static gf_enum_done_t gPendingDone   = nil;
static int            gEnumCalls     = 0;
static int            gEnumFilterPID = -1;

// Grid preferences, settable per test. Defaults match a fresh install: MRU
// order, minimized windows sunk to the end.
static int gStubSortMode      = 0;   // 0 = MRU, 1 = alphabetical by app
static int gStubMinimizedLast = 1;

static void reset_stubs(void) {
    gShowPanelCalls = 0; gShowPanelSelected = -1;
    gHidePanelCalls = 0;
    gActivateCalls  = 0; gActivatedPID = -1;
    gUpdateSelCalls = 0; gLastUpdateSel = -1;
    gReleaseCalls   = 0;
    gPendingDone    = nil;
    gEnumCalls      = 0; gEnumFilterPID = -1;
    gStubSortMode      = 0;
    gStubMinimizedLast = 1;
}

// Build a synthetic window list of `n` entries, pid 100+i, as enumeration
// would hand it back: malloc'd array, strdup'd strings, non-NULL axRef so the
// test can prove the refs are released exactly once.
static gf_window_t *make_list(int n) {
    gf_window_t *l = (gf_window_t *)calloc((size_t)n, sizeof(gf_window_t));
    for (int i = 0; i < n; i++) {
        char buf[32];
        snprintf(buf, sizeof buf, "win%d", i);
        l[i].title    = strdup(buf);
        l[i].appName  = strdup(buf);
        l[i].pid      = 100 + i;
        l[i].windowID = (unsigned int)(1000 + i);
        l[i].zOrder   = i;
        l[i].axRef    = (void *)(intptr_t)(0x1000 + i); // opaque, never dereferenced
    }
    return l;
}

// A window to synthesize. pid is assigned as 100 + position in the spec array,
// so a test can identify where an entry landed after sorting by committing on
// an index and reading back which pid was activated.
typedef struct {
    const char *app;
    const char *title;
    int         minimized;
} spec_t;

static gf_window_t *make_spec_list(const spec_t *specs, int n) {
    gf_window_t *l = (gf_window_t *)calloc((size_t)n, sizeof(gf_window_t));
    for (int i = 0; i < n; i++) {
        l[i].title     = strdup(specs[i].title);
        l[i].appName   = strdup(specs[i].app);
        l[i].pid       = 100 + i;
        l[i].windowID  = (unsigned int)(1000 + i);
        l[i].zOrder    = i;
        l[i].minimized = specs[i].minimized;
        l[i].axRef     = (void *)(intptr_t)(0x1000 + i);
    }
    return l;
}

static void deliver_specs(const spec_t *specs, int n) {
    gf_enum_done_t done = gPendingDone;
    gPendingDone = nil;
    if (!done) {
        fprintf(stderr, "  !! deliver_specs() with no snapshot in flight\n");
        exit(1);
    }
    done(make_spec_list(specs, n), n);
}

// Which pid ended up at `idx` after sorting: select it, commit, read it back.
static int pid_at(int idx) {
    gfSetSelection(idx);
    gfOnCommit();
    return gActivatedPID;
}

// Fire the parked completion with a fresh n-entry list.
static void deliver(int n) {
    gf_enum_done_t done = gPendingDone;
    gPendingDone = nil;
    if (!done) {
        fprintf(stderr, "  !! deliver() with no snapshot in flight\n");
        exit(1);
    }
    done(make_list(n), n);
}

void gf_enumerateWindowsAsync(int filterPID, gf_enum_done_t done) {
    gEnumCalls++;
    gEnumFilterPID = filterPID;
    gPendingDone = [done copy];
}

gf_window_t *gf_enumerateWindows(int *out_count, int filterPID) {
    (void)filterPID;
    *out_count = 0;
    return NULL;
}

void  gf_showPanel(void *data, int selected) {
    gShowPanelCalls++; gShowPanelSelected = selected; free(data);
}
void  gf_updatePanelEntries(void *data, int selected) {
    (void)selected; free(data);
}
void  gf_updateSelection(int selected) { gUpdateSelCalls++; gLastUpdateSel = selected; }
void  gf_hidePanel(void)               { gHidePanelCalls++; }
void  gf_release(void *axRef)          { (void)axRef; gReleaseCalls++; }

void gf_activateWindow(void *axRef, int pid, int minimized, int windowless) {
    (void)axRef; (void)minimized; (void)windowless;
    gActivateCalls++; gActivatedPID = pid;
}

// Panel data is an opaque blob to the switcher; a single malloc suffices.
void *gf_newPanelData(int count) { (void)count; return malloc(1); }
void  gf_setPanelEntry(void *data, int idx, const char *title, const char *appName,
                       void *axRef, unsigned int windowID, int minimized, int pid,
                       int unresponsive, int windowless) {
    (void)data; (void)idx; (void)title; (void)appName; (void)axRef; (void)windowID;
    (void)minimized; (void)pid; (void)unresponsive; (void)windowless;
}

int  gf_frontmostPID(void)   { return 4242; }

int  gf_getSortMode(void)     { return gStubSortMode; }
int  gf_getMinimizedLast(void){ return gStubMinimizedLast; }
int  gf_toggleSortMode(void)  { gStubSortMode = !gStubSortMode; return gStubSortMode; }
void gf_closeWindow(void *axRef) { (void)axRef; }
void gf_quitApp(int pid)         { (void)pid; }
void gf_focusApp(int pid)        { (void)pid; }

// =========================================================================
// Assertions
// =========================================================================

static int gFailures = 0;
static const char *gCase = "";

static void check(int cond, const char *what) {
    if (cond) {
        printf("  ok   %s\n", what);
    } else {
        printf("  FAIL %s  [%s]\n", what, gCase);
        gFailures++;
    }
}

#define CASE(name) do { gCase = (name); reset_stubs(); printf("%s\n", (name)); } while (0)

// Return the switcher to closed state between cases without asserting on it.
static void close_switcher(void) {
    gfOnCancel();
    if (gPendingDone) { deliver(0); }
    gPendingDone = nil;
}

// =========================================================================
// Cases
// =========================================================================

// Baseline: the ordinary open. Nothing lands between press and arrival.
static void test_plain_open(void) {
    CASE("open: snapshot arrives with no interleaved events");
    check(gfOnHotkey(0, 0) == 1, "hotkey is handled");
    check(gEnumCalls == 1, "one snapshot requested");
    check(gEnumFilterPID == 0, "scope 0 asks for all apps");
    check(gShowPanelCalls == 0, "grid not shown before the list arrives");
    deliver(5);
    check(gShowPanelCalls == 1, "grid shown once on arrival");
    check(gShowPanelSelected == 1, "selection defaults to entry 1");
    close_switcher();
}

// Cmd+` scopes to the frontmost app; the pid must reach enumeration.
static void test_scoped_open(void) {
    CASE("open: scope 1 passes the frontmost pid through");
    gfOnHotkey(0, 1);
    check(gEnumFilterPID == 4242, "frontmost pid forwarded as the filter");
    deliver(3);
    check(gShowPanelCalls == 1, "grid shown");
    close_switcher();
}

// The regression this whole pending-state block exists to prevent: releasing
// the hotkey before the snapshot lands used to hit `if (!gSwOpen) return 0`
// and silently drop the switch.
static void test_commit_before_arrival(void) {
    CASE("quick switch: hotkey released before the snapshot arrives");
    gfOnHotkey(0, 0);
    check(gfOnCommit() == 1, "release is handled, not dropped");
    check(gActivateCalls == 0, "activation deferred until the list exists");
    deliver(5);
    check(gActivateCalls == 1, "window activated on arrival");
    check(gActivatedPID == 101, "activated entry 1 (previously-used window)");
    check(gShowPanelCalls == 0, "grid never shown for a quick switch");
    check(gHidePanelCalls == 1, "teardown still ran");
    close_switcher();
}

// A second Tab inside the pending window must move the selection, not vanish.
static void test_extra_presses_before_arrival(void) {
    CASE("open: further Tab presses while the snapshot is in flight");
    gfOnHotkey(0, 0);
    check(gfOnHotkey(0, 0) == 1, "second press handled");
    check(gfOnHotkey(0, 0) == 1, "third press handled");
    check(gEnumCalls == 1, "no duplicate snapshot requested");
    deliver(5);
    check(gShowPanelSelected == 3, "selection advanced 1 -> 3");
    close_switcher();
}

// Shift+Tab while pending reverses, and the index wraps rather than going
// negative.
static void test_shift_press_before_arrival(void) {
    CASE("open: Shift+Tab while pending reverses and wraps");
    gfOnHotkey(0, 0);
    gfOnHotkey(1, 0);   // back one from entry 1 -> entry 0
    gfOnHotkey(1, 0);   // back one more -> wraps to the last entry
    deliver(5);
    check(gShowPanelSelected == 4, "selection wrapped to the last entry");
    close_switcher();
}

// Escape during the pending window must abandon the snapshot outright.
static void test_cancel_before_arrival(void) {
    CASE("cancel: Escape before the snapshot arrives");
    gfOnHotkey(0, 0);
    check(gfOnCancel() == 1, "cancel is handled while pending");
    deliver(5);
    check(gShowPanelCalls == 0, "abandoned snapshot does not open a grid");
    check(gActivateCalls == 0, "and does not activate anything");
    check(gReleaseCalls == 5, "every AX ref in the dropped list was released");
    close_switcher();
}

// A cancel followed by a fresh press means two completions are outstanding.
// Only the newer one may install itself.
static void test_superseded_snapshot(void) {
    CASE("generation: a stale completion is dropped, the current one wins");
    gfOnHotkey(0, 0);
    gf_enum_done_t stale = gPendingDone;
    gPendingDone = nil;
    gfOnCancel();               // abandons the first request

    gfOnHotkey(0, 0);           // second request, new generation
    check(gEnumCalls == 2, "a second snapshot was requested");
    stale(make_list(5), 5);     // the abandoned one lands late
    check(gShowPanelCalls == 0, "stale completion ignored");
    deliver(3);
    check(gShowPanelCalls == 1, "current completion still opens the grid");
    check(gShowPanelSelected == 1, "with its own default selection");
    close_switcher();
}

// An empty desktop: enumeration finds nothing, so no grid and no stuck
// pending flag — a following press must be able to start over.
static void test_empty_snapshot(void) {
    CASE("open: empty snapshot leaves the switcher closed and reusable");
    gfOnHotkey(0, 0);
    deliver(0);
    check(gShowPanelCalls == 0, "no grid for an empty list");
    check(gfOnHotkey(0, 0) == 1, "a later press starts a fresh snapshot");
    check(gEnumCalls == 2, "pending flag was cleared, not latched");
    close_switcher();
}

// Once open, cycling and committing must behave exactly as before the split.
static void test_cycle_and_commit_when_open(void) {
    CASE("open grid: cycle then commit");
    gfOnHotkey(0, 0);
    deliver(5);
    check(gfOnHotkey(0, 0) == 1, "Tab while open is handled");
    check(gUpdateSelCalls == 1, "selection update pushed to the panel");
    check(gLastUpdateSel == 2, "advanced 1 -> 2");
    check(gEnumCalls == 1, "no re-enumeration while open");
    check(gfOnCommit() == 1, "commit handled");
    check(gActivatedPID == 102, "activated the cycled-to window");
    close_switcher();
}

// Nothing in flight and nothing open: these must stay no-ops.
static void test_idle_events(void) {
    CASE("idle: commit and cancel with nothing open");
    check(gfOnCommit() == 0, "commit is a no-op");
    check(gfOnCancel() == 0, "cancel is a no-op");
    check(gActivateCalls == 0, "nothing activated");
}

// The "Show minimized windows last" preference was honoured only in MRU order,
// where it is baked into zOrder. Alphabetical order sorts on name alone, so a
// minimized window kept its alphabetical slot and appeared early in the grid.
static void test_by_app_sinks_minimized(void) {
    CASE("sort by app: minimized sinks below live windows when enabled");
    gStubSortMode = 1;
    gStubMinimizedLast = 1;
    // Alpha would sort first by name; minimized, it must end up last.
    const spec_t specs[] = {
        { "Alpha", "a", 1 },   // pid 100, minimized
        { "Zulu",  "z", 0 },   // pid 101, live
    };
    gfOnHotkey(0, 0);
    deliver_specs(specs, 2);
    check(gShowPanelCalls == 1, "grid shown");
    check(pid_at(0) == 101, "live Zulu takes the first slot");
    close_switcher();

    CASE("sort by app: minimized keeps its alphabetical slot when disabled");
    gStubSortMode = 1;
    gStubMinimizedLast = 0;
    gfOnHotkey(0, 0);
    deliver_specs(specs, 2);
    check(pid_at(0) == 100, "minimized Alpha sorts by name as before");
    close_switcher();
}

// Minimized sinks below live windows but stays ahead of the placeholder
// groups, and ties still fall back to name order.
static void test_by_app_rank_order(void) {
    CASE("sort by app: live < minimized < windowless < unresponsive");
    gStubSortMode = 1;
    gStubMinimizedLast = 1;
    const spec_t specs[] = {
        { "Zulu",  "z", 0 },   // pid 100 live
        { "Alpha", "a", 1 },   // pid 101 minimized
        { "Bravo", "b", 0 },   // pid 102 live
        { "Delta", "d", 1 },   // pid 103 minimized
    };
    gfOnHotkey(0, 0);
    deliver_specs(specs, 4);
    check(pid_at(0) == 102, "live Bravo first");
    close_switcher();

    gfOnHotkey(0, 0);
    deliver_specs(specs, 4);
    check(pid_at(1) == 100, "live Zulu second");
    close_switcher();

    gfOnHotkey(0, 0);
    deliver_specs(specs, 4);
    check(pid_at(2) == 101, "minimized Alpha third, sunk below both live");
    close_switcher();

    gfOnHotkey(0, 0);
    deliver_specs(specs, 4);
    check(pid_at(3) == 103, "minimized Delta last, name order within the group");
    close_switcher();
}

// MRU order must keep working off zOrder, untouched by the new rank helper.
static void test_mru_sort_uses_zorder(void) {
    CASE("sort by MRU: order still follows zOrder");
    gStubSortMode = 0;
    gStubMinimizedLast = 1;
    // zOrder is assigned in spec order, so pid 100 stays frontmost regardless
    // of name or minimized state.
    const spec_t specs[] = {
        { "Zulu",  "z", 1 },   // pid 100, minimized but zOrder 0
        { "Alpha", "a", 0 },   // pid 101
    };
    gfOnHotkey(0, 0);
    deliver_specs(specs, 2);
    check(pid_at(0) == 100, "zOrder wins in MRU mode, not name or minimized");
    close_switcher();
}

int main(void) {
    @autoreleasepool {
        test_plain_open();
        test_scoped_open();
        test_commit_before_arrival();
        test_extra_presses_before_arrival();
        test_shift_press_before_arrival();
        test_cancel_before_arrival();
        test_superseded_snapshot();
        test_empty_snapshot();
        test_cycle_and_commit_when_open();
        test_idle_events();
        test_by_app_sinks_minimized();
        test_by_app_rank_order();
        test_mru_sort_uses_zorder();

        printf("\n%s\n", gFailures ? "FAILED" : "all switcher tests passed");
        return gFailures ? 1 : 0;
    }
}
