#pragma once

// Switcher state machine — the event-driven core that owns the window list,
// the selected index, and the open/closed state. Formerly switcher.go; these
// functions were the cgo //export surface and are now plain C, called directly
// by the event tap and panel UI in cocoa.m.
//
// All five are invoked on the main thread (the event-tap source and the panel
// mouse handlers both run on the main run loop). They guard the shared state
// with an internal mutex regardless, matching the original's contract.
//
//   shift: nonzero reverses cycle direction.
//   scope: 0 = all regular apps (Cmd+Tab), 1 = frontmost app only (Cmd+`).
//
// gfOnHotkey / gfOnCommit / gfOnCancel / gfOnClose return 1 if they handled
// the event (the tap should swallow it) and 0 otherwise.

int  gfOnHotkey(int shift, int scope);
int  gfOnCommit(void);
int  gfOnCancel(void);
void gfSetSelection(int idx);
int  gfOnClose(int idx);
