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
                       int minimized, int pid, int unresponsive);
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

// Bulk window arrangement, driven by the menu-bar status item.
// Both operate on every standard window of every regular app (same filter
// gf_enumerateWindows uses).
void gf_minimizeAll(void);
void gf_cascadeAll(void);

// LaunchAgent management for the "Start at boot" menu item.
//   * gf_isLaunchAgentInstalled — does the per-user plist exist on disk
//   * gf_installLaunchAgent     — write the plist pointing at the running
//                                 binary's path. Effective on next login;
//                                 we deliberately do not launchctl-load it
//                                 now to avoid spawning a second instance.
//   * gf_uninstallLaunchAgent   — remove the plist. If we're currently
//                                 running under launchd, also bootout so
//                                 we don't get re-launched after exit.
// Return 0 on success, non-zero on failure.
int  gf_isLaunchAgentInstalled(void);
int  gf_installLaunchAgent(void);
int  gf_uninstallLaunchAgent(void);
