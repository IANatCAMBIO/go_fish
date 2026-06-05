# go_fish

A fast, lightweight macOS window switcher with a thumbnail grid. Replaces
Cmd+Tab — which switches between *apps* — with a per-window switcher that
lets you jump directly to a specific window, even across many windows of
the same app.

## Features

- **Cmd+Tab** opens a thumbnail grid of every window across every app
- **Cmd+\`** scopes the grid to the current app's windows
- **MRU sorted** — a quick tap-and-release Cmd+Tab toggles between your
  two most recent windows
- **Keyboard + mouse** — Tab / Shift+Tab to cycle, hover to select,
  click to commit
- **Per-tile metadata** — app name above the thumbnail, window title
  below, and an **X** button to close the window without leaving the grid
- **Includes minimized windows** (shown with the app icon); selecting one
  restores it
- **Resilient to unresponsive apps** — apps that don't respond within
  100 ms still appear in the grid as a placeholder with a "not responding"
  badge, so a hung app can't stall the switcher
- **Space-aware** — activating a window on another Space switches Spaces
  automatically
- **Menu-bar entry** with Show Window Grid, Minimize All, Cascade All,
  Start at boot, Secure Event Input detection, and Quit
- **Opt-in auto-launch** — toggle **Start at boot** in the menu to add
  go_fish to your Login Items (System Settings > General > Login Items),
  with a built-in 3-attempt backoff so a missing permission can never
  turn into a per-login prompt loop
- **Secure Event Input awareness** — when an app holds Secure Event
  Input (Terminal during `sudo`, password managers, some VPN clients),
  Cmd+Tab is invisible to *any* third-party event tap. go_fish polls
  for this state and overlays a red X on the menu-bar icon so you know
  the switcher is temporarily unavailable and why.
- **Thumbnail caching** so the grid opens instantly for recently-focused
  windows
- **Auto-sized panel** that adapts to the number of open windows
- **Parallel window enumeration** — the per-app AX queries run
  concurrently via GCD, so total grid-open latency is `max(per-app
  latency)` rather than the sum across every running app
- **Always-on background app** ~0% idle CPU, ~60–80 MB resident
- **Scoped to one Space** With multiple Spaces in MacOS, go_fish will only show apps on your current space

## Quickstart

```sh
# Build go_fish.app from ./src into the repo root. No sudo.
# Requires Xcode Command Line Tools (clang).
./build.sh

# Launch it (it's a menu-bar app; no auto-launch by default):
open go_fish.app
```

`build.sh` compiles the Objective-C sources, generates the app icon from
`src/hook.png`, assembles `./go_fish.app`, and ad-hoc signs it. Move the
bundle wherever you like (e.g. `~/Applications`) — it's self-contained.

The first launch will prompt for two permissions in **System Settings →
Privacy & Security**:

1. **Accessibility** → enable `go_fish`
2. **Screen Recording** → enable `go_fish`

Then re-launch. Also under **System Settings → Keyboard → Keyboard
Shortcuts**:

3. **Mission Control** → uncheck Cmd+Tab
4. **Keyboard** → uncheck "Move focus to next window in active app"
   (Cmd+\`)

Press Cmd+Tab. The grid pops up. Cycle with Tab, release Cmd to commit,
Esc to cancel. If you want go_fish back automatically next login, click
the menu-bar hook and check **Start at boot**.

## Repo layout

```
go_fish/
├── README.md
├── build.sh               # compiles ./src → ./go_fish.app (no auto-launch by default)
├── go_fish.app            # the built bundle (produced by build.sh)
├── docs/{USAGE,BUILDING}.md
└── src/                   # Objective-C source + Info.plist + embedded hook.png
```

## Documentation

- [docs/USAGE.md](docs/USAGE.md) — full keyboard/mouse reference, menu
  items, auto-launch / "Start at boot", Secure Event Input behavior,
  configuration, troubleshooting
- [docs/BUILDING.md](docs/BUILDING.md) — build requirements, code
  signing, cross-compilation

## How it works

Written in Objective-C against AppKit, Accessibility, and CoreGraphics:

- **Hotkey capture** — a global `CGEventTap` intercepts Cmd+Tab and
  Cmd+\` before they reach the focused app. macOS Secure Event Input
  bypasses *all* third-party taps; a 1.5 s poller against
  `IsSecureEventInputEnabled()` (resolved via `dlsym`) detects this and
  paints a red-X overlay on the menu-bar icon so the user knows the
  switcher is unavailable and why.
- **Window enumeration** — `kAXWindowsAttribute` per running app,
  snapshotted on demand (no background polling) and parallelized across
  apps via `dispatch_apply` so latency scales with the slowest app, not
  the sum of all apps. A 100 ms per-app
  `AXUIElementSetMessagingTimeout` guards against unresponsive processes
  stalling the snapshot; the offending app appears as a placeholder
  instead.
- **MRU tracking** — fed by
  `NSWorkspaceDidActivateApplicationNotification` plus per-app
  `AXObserver` callbacks on focused-window changes
- **Thumbnails** — `CGWindowListCreateImage` resolved via `dlsym` (the
  symbol was obsoleted in the macOS 15 SDK headers but still ships in
  CoreGraphics at runtime), downscaled to 600 px and LRU-cached by
  `CGWindowID`
- **Activation** — `kAXMinimizedAttribute = false` + `kAXRaiseAction` +
  `NSRunningApplication.activateWithOptions:`; macOS handles the Space
  switch as a side-effect
- **Optional auto-launch** — the **Start at boot** menu item adds the
  enclosing `go_fish.app` bundle to the per-user Login Items list via the
  `LSSharedFileList` session list. Registering the *bundle* (not the bare
  binary) is what lets it launch with no Terminal window: LaunchServices
  runs a `.app` directly, whereas a loose Unix binary in Login Items is
  hosted by Terminal.app. The binary tracks permission-failure attempts
  in `~/Library/Application Support/go_fish/attempts.txt`, giving up
  cleanly (`exit 0`) after the 3rd failed preflight so a missing grant
  can't re-prompt on every login.

