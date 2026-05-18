# Building go-fish

## Requirements

- macOS 12 or later (tested on macOS 14/15, arm64 and x86_64)
- Go 1.22+
- Xcode Command Line Tools (`xcode-select --install`) — provides clang and the macOS SDK
- No third-party Go modules: the build uses only `cgo` against system frameworks

## Build

Source code lives under `src/`. From the repo root:

```sh
( cd src && go build -o ../bin/go-fish )
```

…which is exactly what `./install.sh --build` does for you.

This produces a single `bin/go-fish` binary (~2–3 MB). To strip symbols
and shrink:

```sh
( cd src && go build -ldflags="-s -w" -o ../bin/go-fish )
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
( cd src && GOCACHE=/tmp/gocache go build -o ../bin/go-fish )
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
( cd src && GOARCH=arm64 go build -o ../bin/go-fish-arm64 )
( cd src && GOARCH=amd64 go build -o ../bin/go-fish-amd64 )
lipo -create -output bin/go-fish bin/go-fish-arm64 bin/go-fish-amd64
```

## Code signing (optional but recommended)

macOS remembers the granted Accessibility / Screen Recording permissions
**per signing identity**. An unsigned, rebuilt binary will be treated as a
new app each time and re-prompt for permissions.

`./install.sh` does an ad-hoc sign (`codesign --force --sign -`) on
`bin/go-fish` before copying it to `/usr/local/bin`, which gives the
binary a stable hash identity across rebuilds. If you want to sign with
your Apple Developer ID instead, do it before running the installer (or
re-sign the installed copy):

```sh
codesign --sign - --force bin/go-fish                                  # ad-hoc (what install.sh does)
codesign --sign "Developer ID Application: …" --options runtime bin/go-fish
```

After re-signing, you may need to remove and re-grant the permissions
once.

## Project layout

```
go_fish/
├── README.md
├── install.sh             # build / install / uninstall the LaunchAgent
├── bin/
│   └── go-fish            # prebuilt binary; --build writes here
├── docs/
│   ├── BUILDING.md
│   └── USAGE.md
└── src/
    ├── go.mod             # module declaration, no third-party deps
    ├── main.go            # entry point, permission checks, runs NSApp
    ├── switcher.go        # Go state machine; exports gfOnHotkey / gfOnCommit / gfOnCancel / gfSetSelection to C
    ├── cocoa.h            # C interface between Go and Objective-C
    ├── cocoa.m            # Cocoa: event tap, AX enumeration, panel UI, status item, MRU, thumbnail cache, activation
    └── hook.png           # menu-bar icon, embedded via go:embed
```

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
