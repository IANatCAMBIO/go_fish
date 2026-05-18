# go-fish

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
- **Includes minimized windows** (shown with the app icon); selecting one
  restores it
- **Space-aware** — activating a window on another Space switches Spaces
  automatically
- **Menu-bar entry** with show-grid and quit options
- **Thumbnail caching** so the grid opens instantly for recently-focused
  windows
- **Auto-sized panel** that adapts to the number of open windows
- **Always-on background app** ~0% idle CPU, ~60–80 MB resident
- **Scoped to one Space** With multiple Spaces in MacOS, go_fish will only show apps on your current space

## Quickstart

```sh
# Build + install in one shot (compiles ./src → ./bin/go-fish,
# then copies to /usr/local/bin and loads the LaunchAgent).
# Requires Go 1.22+ and Xcode Command Line Tools.
./install.sh --build

# Or, if you already have a prebuilt binary at ./bin/go-fish:
./install.sh

# Uninstall:
./install.sh uninstall
```

After installing, finish setup in **System Settings**:

1. **Privacy & Security → Accessibility** → enable `/usr/local/bin/go-fish`
2. **Privacy & Security → Screen Recording** → enable `/usr/local/bin/go-fish`
3. **Keyboard → Keyboard Shortcuts → Mission Control** → uncheck Cmd+Tab
4. **Keyboard → Keyboard Shortcuts → Keyboard** → uncheck "Move focus to
   next window in active app" (Cmd+\`)

Then press Cmd+Tab. The grid pops up. Cycle with Tab, release Cmd to
commit, Esc to cancel.

## Repo layout

```
go_fish/
├── README.md
├── install.sh             # build / install / uninstall the LaunchAgent
├── bin/go-fish            # prebuilt binary (also produced by --build)
├── docs/{USAGE,BUILDING}.md
└── src/                   # Go + Objective-C source + embedded hook.png
```

## Documentation

- [docs/USAGE.md](docs/USAGE.md) — full keyboard/mouse reference,
  LaunchAgent management, configuration, troubleshooting
- [docs/BUILDING.md](docs/BUILDING.md) — build requirements, code
  signing, cross-compilation

## How it works

Written in Go with a CGO bridge to AppKit, Accessibility, and
CoreGraphics:

- **Hotkey capture** — a global `CGEventTap` intercepts Cmd+Tab and
  Cmd+\` before they reach the focused app
- **Window enumeration** — `kAXWindowsAttribute` per running app,
  snapshotted on demand (no background polling)
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

