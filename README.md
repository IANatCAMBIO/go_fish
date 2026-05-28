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
- **Opt-in auto-launch** — toggle **Start at boot** in the menu to
  install a LaunchAgent (with a built-in 3-attempt backoff so a missing
  permission can never turn into a restart loop)
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
# Build + install in one shot (compiles ./src → ./bin/go_fish, then
# copies to ~/Applications/go_fish). No sudo, no LaunchAgent by default.
# Requires Go 1.22+ and Xcode Command Line Tools.
./install.sh --build

# Or, if you already have a prebuilt binary at ./bin/go_fish:
./install.sh

# Total uninstall (kills process, removes LaunchAgent if installed,
# removes binary, prompts to remove logs):
./install.sh uninstall
```

After installing, launch go_fish (it does not start automatically). For
the first run, detach from the terminal so closing the shell doesn't
kill the process and you don't get a noisy log stream:

```sh
nohup ~/Applications/go_fish >/dev/null 2>&1 &
```

The first launch will prompt for two permissions in **System Settings →
Privacy & Security**:

1. **Accessibility** → enable `~/Applications/go_fish`
2. **Screen Recording** → enable `~/Applications/go_fish`

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
├── install.sh             # build / install / uninstall (no LaunchAgent by default)
├── bin/go_fish            # prebuilt binary (also produced by --build)
├── docs/{USAGE,BUILDING}.md
└── src/                   # Go + Objective-C source + embedded hook.png
```

## Documentation

- [docs/USAGE.md](docs/USAGE.md) — full keyboard/mouse reference, menu
  items, auto-launch / "Start at boot", Secure Event Input behavior,
  configuration, troubleshooting
- [docs/BUILDING.md](docs/BUILDING.md) — build requirements, code
  signing, cross-compilation

## How it works

Written in Go with a CGO bridge to AppKit, Accessibility, and
CoreGraphics:

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
- **Optional auto-launch** — the **Start at boot** menu item writes
  `~/Library/LaunchAgents/com.local.gofish.plist` pointing at the
  running binary's `realpath`. The plist sets `ThrottleInterval=30`,
  and the binary itself tracks permission-failure attempts in
  `~/Library/Application Support/go_fish/attempts.txt`, giving up
  cleanly (`exit 0`) after the 3rd failed preflight so launchd's
  `SuccessfulExit=false` doesn't loop.

