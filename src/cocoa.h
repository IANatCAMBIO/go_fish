#pragma once

#include <stdint.h>

// One window's metadata, returned by gf_enumerateWindows.
// All pointer/string fields are owned by the caller and must be freed:
//   - title, appName: free()
//   - axRef: gf_release() (NULL is allowed for unresponsive-app placeholders)
typedef struct {
    int          pid;
    void        *axRef;       // AXUIElementRef, retained (+1); NULL if unresponsive
    unsigned int windowID;    // CGWindowID, 0 if unknown
    char        *title;       // strdup'd
    char        *appName;     // strdup'd
    int          minimized;   // 0 / 1
    int          onScreen;    // 0 / 1
    int          zOrder;      // smaller = closer to front
    int          unresponsive;// 0 / 1; if 1, axRef is NULL and entry is a per-app placeholder
    int          windowless;  // 0 / 1; if 1, a running regular app with no windows.
                              // axRef is NULL and the entry is a per-app placeholder;
                              // activating just brings the app forward.
} gf_window_t;

// Permissions.
int  gf_hasAccessibility(void);
void gf_promptAccessibility(void);
int  gf_hasScreenRecording(void);
void gf_promptScreenRecording(void);

// Lifecycle. iconBytes points to JPEG data for the menu-bar icon (may be NULL
// to skip installing a status item).
void gf_run(const void *iconBytes, int iconLen);

// Enumeration / release.
// filterPID == 0 means all regular apps; otherwise only that pid's windows.
gf_window_t *gf_enumerateWindows(int *out_count, int filterPID);
void         gf_release(void *axRef);

// PID of the current frontmost application, or 0 if none.
int          gf_frontmostPID(void);

// Panel data builder. gf_showPanel / gf_updatePanelEntries take ownership and free it.
void *gf_newPanelData(int count);
void  gf_setPanelEntry(void *data, int idx,
                       const char *title, const char *appName,
                       void *axRef, unsigned int windowID,
                       int minimized, int pid, int unresponsive, int windowless);
void  gf_showPanel(void *data, int selected);
// In-place entry refresh without resizing/recentering the panel. Used after
// closing a window so the grid updates without a visible jump.
void  gf_updatePanelEntries(void *data, int selected);
void  gf_updateSelection(int selected);
void  gf_hidePanel(void);

// Activation. Brings window + app forward; if on another Space, the system
// switches Spaces as a side-effect of activating the app.
void gf_activateWindow(void *axRef, int pid, int minimized);

// Close. Presses the target window's AX close button. Caller retains ownership
// of axRef (this function does not release it).
void gf_closeWindow(void *axRef);

// Quit. Gracefully terminates the app (like Cmd+Q). Used to "close" windowless
// app placeholders, which have no window to close.
void gf_quitApp(int pid);

// Bulk window arrangement, driven by the menu-bar status item.
// Both operate on every standard window of every regular app (same filter
// gf_enumerateWindows uses).
void gf_minimizeAll(void);
void gf_cascadeAll(void);

// Login-item management for the "Start at boot" menu item. Adds / removes the
// running binary from the per-user Login Items list (System Settings >
// General > Login Items) — the same list the "+" button populates. Backed by
// the LSSharedFileList session list, the only programmatic path that works for
// a bare binary (SMAppService requires a real .app bundle).
//   * gf_isLoginItemInstalled — is the currently-running binary in the list.
//                               Matches by resolved path, so a stale entry for
//                               a different binary location (e.g. an old
//                               dev-build path) reports as not installed; the
//                               menu reflects whether *this* binary will start
//                               at boot.
//   * gf_installLoginItem     — add the running binary. Effective on next
//                               login; we deliberately do not relaunch now.
//   * gf_uninstallLoginItem   — remove the running binary's entry.
// Return 0 on success, non-zero on failure.
int  gf_isLoginItemInstalled(void);
int  gf_installLoginItem(void);
int  gf_uninstallLoginItem(void);
