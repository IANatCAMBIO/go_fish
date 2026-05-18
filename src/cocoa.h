#pragma once

#include <stdint.h>

// One window's metadata, returned by gf_enumerateWindows.
// All pointer/string fields are owned by the caller and must be freed:
//   - title, appName: free()
//   - axRef: gf_release()
typedef struct {
    int          pid;
    void        *axRef;     // AXUIElementRef, retained (+1)
    unsigned int windowID;  // CGWindowID, 0 if unknown
    char        *title;     // strdup'd
    char        *appName;   // strdup'd
    int          minimized; // 0 / 1
    int          onScreen;  // 0 / 1
    int          zOrder;    // smaller = closer to front
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

// Panel data builder. gf_showPanel takes ownership and frees it.
void *gf_newPanelData(int count);
void  gf_setPanelEntry(void *data, int idx,
                       const char *title, const char *appName,
                       void *axRef, unsigned int windowID,
                       int minimized, int pid);
void  gf_showPanel(void *data, int selected);
void  gf_updateSelection(int selected);
void  gf_hidePanel(void);

// Activation. Brings window + app forward; if on another Space, the system
// switches Spaces as a side-effect of activating the app.
void gf_activateWindow(void *axRef, int pid, int minimized);
