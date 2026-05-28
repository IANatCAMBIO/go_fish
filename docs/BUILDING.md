# Building go_fish

## Requirements

- macOS 12 or later (tested on macOS 14/15, arm64 and x86_64)
- Go 1.22+
- Xcode Command Line Tools (`xcode-select --install`) — provides clang and the macOS SDK
- No third-party Go modules: the build uses only `cgo` against system frameworks

## Build

Source code lives under `src/`. From the repo root:

```sh
( cd src && go build -o ../bin/go_fish )
```

…which is exactly what `./install.sh --build` does for you.

This produces a single `bin/go_fish` binary (~2–3 MB). To strip symbols
and shrink:

```sh
( cd src && go build -ldflags="-s -w" -o ../bin/go_fish )
```

### What cgo links against

The cgo preamble in `main.go` requests these system frameworks:

- `Cocoa` — NSApplication, NSPanel, NSImage
- `ApplicationServices` — Accessibility (AX) API
- `CoreGraphics` — `CGEventTap`, window listing, screen capture

`CGWindowListCreateImage` was obsoleted in the macOS 15 SDK headers, so the
build does **not** reference it directly. Instead `cocoa.m` resolves it at
runtime via `dlsym(RTLD_DEFAULT, "CGWindowListCreateImage")`. The symbol is
still shipped in `CoreGraphics.framework`; if Apple eventually removes it,
thumbnails will fall back to app icons and the program will keep working.
The long-term migration is to ScreenCaptureKit.

## Troubleshooting builds

### `permission denied` on `~/Library/Caches/go-build`

The Go build cache is owned by root on some installs (e.g. system-installed
Go run once with `sudo`). Fix permanently:

```sh
sudo chown -R "$USER":staff ~/Library/Caches/go-build
```

Or override per-build:

```sh
( cd src && GOCACHE=/tmp/gocache go build -o ../bin/go_fish )
```

### `'CGWindowListCreateImage' is unavailable: obsoleted in macOS 15.0`

Means an old copy of `cocoa.m` still calls the function directly. Make sure
your `cocoa.m` declares `gCGWindowListCreateImage` via `dlsym` and calls
through that pointer instead.

### `ld: framework not found`

Install / reinstall the Command Line Tools:

```sh
sudo xcode-select --install
```

### Cross-architecture build

For a universal binary covering both Apple Silicon and Intel:

```sh
( cd src && GOARCH=arm64 go build -o ../bin/go_fish-arm64 )
( cd src && GOARCH=amd64 go build -o ../bin/go_fish-amd64 )
lipo -create -output bin/go_fish bin/go_fish-arm64 bin/go_fish-amd64
```

## Code signing

macOS remembers granted Accessibility / Screen Recording permissions
**per signing identity**. What "identity" means depends on how the
binary is signed:

| Signing method                    | TCC identity                | Survives rebuild? |
| --------------------------------- | --------------------------- | ----------------- |
| Unsigned                          | binary path (loose)         | Unreliable; usually re-prompts |
| Ad-hoc (`codesign --sign -`)      | **CDHash** (content hash)   | **No** — content changes → CDHash changes → re-prompt |
| Self-signed cert from Keychain    | cert's identity             | Yes               |
| Developer ID Application          | Team ID + bundle/binary ID  | Yes               |

`./install.sh` does an ad-hoc sign as the convenient default — it
requires no setup and lets the script run unattended. The trade-off is
that **every rebuild re-prompts** for Accessibility/Screen Recording,
because the CDHash changes. The fix is documented in
`USAGE.md` → *After granting permissions, it still complains*.

### Stable identity via a self-signed cert

For a free local fix that survives rebuilds, create a self-signed
code-signing cert in **Keychain Access → Certificate Assistant →
Create a Certificate…**:

- **Name:** anything memorable, e.g. `go_fish-signer`
- **Identity Type:** Self Signed Root
- **Certificate Type:** Code Signing

After creating it, sign manually before running the installer:

```sh
codesign --force --sign go_fish-signer bin/go_fish
./install.sh                              # without --build, so the signed binary is what gets installed
```

The first run after this will prompt for permissions one more time;
subsequent rebuilds signed with the same cert will keep them.

### Developer ID

If you have an Apple Developer account, sign with your Developer ID
instead — same effect as a self-signed cert, plus the binary will work
on machines other than yours:

```sh
codesign --sign "Developer ID Application: …" --options runtime --force bin/go_fish
```

After switching signing identities (ad-hoc → self-signed, self-signed →
Developer ID, etc.), you'll need to remove the old go_fish entry from
System Settings → Privacy & Security → Accessibility (and Screen
Recording) once.

## Project layout

```
go_fish/
├── README.md
├── install.sh             # build / install (~/Applications/go_fish) / uninstall;
│                          #   no LaunchAgent by default — that's opt-in via the
│                          #   "Start at boot" menu item once go_fish is running
├── bin/
│   └── go_fish            # prebuilt binary; --build writes here
├── docs/
│   ├── BUILDING.md
│   └── USAGE.md
└── src/
    ├── go.mod             # module declaration, no third-party deps
    ├── main.go            # entry point, permission preflight with 3-attempt
    │                      #   backoff (attempts.txt), runs NSApp
    ├── switcher.go        # Go state machine; exports gfOnHotkey / gfOnCommit / gfOnCancel / gfSetSelection / gfOnClose to C
    ├── cocoa.h            # C interface between Go and Objective-C
    ├── cocoa.m            # Cocoa: event tap, parallelized AX enumeration,
    │                      #   panel UI, status item + menu (Show / Minimize /
    │                      #   Cascade / Start at boot / SEI detection / Quit),
    │                      #   MRU, thumbnail cache, activation, close, bulk
    │                      #   minimize / cascade, LaunchAgent install/uninstall,
    │                      #   Secure Event Input poller + red-X icon overlay
    └── hook.png           # menu-bar icon, embedded via go:embed
```

### C surface (cocoa.h)

The Go ↔ Objective-C contract is small but worth knowing if you're
editing either side:

- `gf_enumerateWindows(out_count, filterPID)` — main snapshot call.
  Parallelizes per-app AX queries via `dispatch_apply` on the global
  `USER_INTERACTIVE` queue; each worker writes into its own pre-
  allocated slot and a single-threaded merge phase assembles the output
  buffer in stable app order so window ordering / `fallbackZ` are
  identical to the pre-parallel implementation. Per-app messaging
  timeout is 100 ms; unresponsive apps surface as a single
  `unresponsive=1` entry with `axRef=NULL`. Emits a `go_fish: enumerate
  N apps -> M windows in X.X ms` line to stderr on every call.
- `gf_activateWindow(axRef, pid, minimized)` — un-minimize + raise +
  activate. Accepts `axRef=NULL` for unresponsive placeholders (falls
  back to app-only activation via `NSRunningApplication`).
- `gf_closeWindow(axRef)` — presses the window's AX close button.
- `gf_minimizeAll()` / `gf_cascadeAll()` — menu-bar bulk actions.
- `gf_showPanel(data, selected)` — full panel show with resize +
  recenter.
- `gf_updatePanelEntries(data, selected)` — in-place entry refresh
  (no resize/recenter); used after closing a window so the panel
  doesn't visually jump.
- `gf_updateSelection(selected)` — fast-path selection change. Dirties
  only the previously-selected and newly-selected cells so mouse-hover
  redraws stay cheap with large grids.
- `gf_isLaunchAgentInstalled()` / `gf_installLaunchAgent()` /
  `gf_uninstallLaunchAgent()` — backing the **Start at boot** menu
  toggle. Install writes the plist (pointing at
  `_NSGetExecutablePath()` resolved through `realpath`) but does *not*
  `launchctl load` — we don't want to spawn a second instance under
  launchd's management while one is already running. Uninstall removes
  the plist; if the current process is itself running under launchd
  (`getppid() == 1`), it also schedules a fire-and-forget `launchctl
  bootout` so the agent detaches.

The menu-bar icon is embedded into the binary at build time via a `go:embed`
directive in `main.go`, so the resulting executable is fully self-contained —
no asset files need to ship alongside it. To swap the icon, replace
`hook.png` (or update the embed path in `main.go`) and rebuild. `cocoa.m`
handles both source styles:

- **Transparent-background** images (PNG with alpha) — used as-is; the
  alpha channel already encodes the silhouette.
- **Opaque-background** images (JPEG, black-on-white) — `cocoa.m` maps
  luminance to alpha so the bright background becomes transparent.

In either case the result is set as a `template` `NSImage`, so AppKit
recolors it automatically for light/dark menu bars and click highlight.

The `runtime.LockOSThread()` call in `main.go:init()` is required: Cocoa's
main run loop must run on the process's main OS thread, and
`C.gf_run()` blocks that thread for the lifetime of the app.
