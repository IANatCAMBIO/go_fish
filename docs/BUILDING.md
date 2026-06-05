# Building go_fish

## Requirements

- macOS 12 or later (tested on macOS 14/15, arm64 and x86_64)
- Xcode Command Line Tools (`xcode-select --install`) — provides clang, `xxd`,
  `sips`, `iconutil`, and the macOS SDK
- No third-party dependencies: the build is pure Objective-C against system
  frameworks

## Build

Source code lives under `src/`. From the repo root, one script does
everything:

```sh
./build.sh               # compiles ./src → ./go_fish.app
```

`build.sh` generates `hook_png.h` (the embedded menu-bar icon, via
`xxd -i hook.png`), compiles `main.m`, `cocoa.m`, and `switcher.m` with clang
(the executable is ~130 KB), and assembles the bundle in the repo root:
`go_fish.app/Contents/MacOS/go_fish`, `Contents/Info.plist` (copied from
`src/Info.plist`), and `Contents/Resources/AppIcon.icns`. The icon is built
from the *same* `hook.png` the menu bar uses: `sips` renders the ten required
sizes into an `.iconset` and `iconutil` packs them into `AppIcon.icns`
(referenced via `CFBundleIconFile` in the plist). Because the hook is a
transparent black silhouette it reads well on light backgrounds and faintly on
dark ones — swap in a backed PNG if you want more contrast. Finally the bundle
is ad-hoc signed. The bundle is what makes go_fish launch as a Login Item with
no Terminal window; see
[USAGE.md](USAGE.md#auto-launch-on-login-start-at-boot).

`build.sh` rebuilds `go_fish.app` from scratch each run (`rm -rf` first), so
there's no separate clean step; `hook_png.h` is left in `src/` (gitignored).

### What it links against

`build.sh` links these system frameworks:

- `Cocoa` — NSApplication, NSPanel, NSImage
- `ApplicationServices` — Accessibility (AX) API
- `CoreGraphics` — `CGEventTap`, window listing, screen capture
- `CoreServices` — `LSSharedFileList` (the **Start at boot** Login Items entry)

`CGWindowListCreateImage` was obsoleted in the macOS 15 SDK headers, so the
build does **not** reference it directly. Instead `cocoa.m` resolves it at
runtime via `dlsym(RTLD_DEFAULT, "CGWindowListCreateImage")`. The symbol is
still shipped in `CoreGraphics.framework`; if Apple eventually removes it,
thumbnails will fall back to app icons and the program will keep working.
The long-term migration is to ScreenCaptureKit.

The build passes `-Wno-deprecated-declarations` because both the `dlsym`'d
capture path and the `LSSharedFileList` login-item calls are formally
deprecated but still functional. (`SMAppService` is the modern login-item
API and would work now that go_fish ships as a bundle, but `LSSharedFileList`
remains in place as the lighter-touch change.)

## Troubleshooting builds

### `'CGWindowListCreateImage' is unavailable: obsoleted in macOS 15.0`

Means an old copy of `cocoa.m` still calls the function directly. Make sure
your `cocoa.m` declares `gCGWindowListCreateImage` via `dlsym` and calls
through that pointer instead.

### `xxd: command not found`

`xxd` ships with the Command Line Tools (and with Vim). Reinstall them:

```sh
sudo xcode-select --install
```

### `ld: framework not found`

Install / reinstall the Command Line Tools:

```sh
sudo xcode-select --install
```

### Cross-architecture build

clang produces a universal binary directly — add both arches to the `clang`
invocation in `build.sh` (the `-fobjc-arc -Wall …` line): append
`-arch arm64 -arch x86_64`. For a one-off without editing the script:

```sh
( cd src && xxd -i hook.png > hook_png.h && \
  clang -fobjc-arc -Wno-deprecated-declarations -O2 -arch arm64 -arch x86_64 \
    main.m cocoa.m switcher.m \
    -framework Cocoa -framework ApplicationServices \
    -framework CoreGraphics -framework CoreServices \
    -o ../go_fish.app/Contents/MacOS/go_fish )
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

`./build.sh` does an ad-hoc sign as the convenient default — it
requires no setup. The trade-off is that **every rebuild re-prompts** for
Accessibility/Screen Recording, because the CDHash changes. The fix is
documented in `USAGE.md` → *After granting permissions, it still complains*.

### Stable identity via a self-signed cert

For a free local fix that survives rebuilds, create a self-signed
code-signing cert in **Keychain Access → Certificate Assistant →
Create a Certificate…**:

- **Name:** anything memorable, e.g. `go_fish-signer`
- **Identity Type:** Self Signed Root
- **Certificate Type:** Code Signing

After creating it, sign the bundle with it once `build.sh` has produced it.
Since `build.sh` ad-hoc signs at the end, re-sign with your identity
afterward (this replaces the ad-hoc signature):

```sh
./build.sh
codesign --force --deep --sign go_fish-signer go_fish.app
```

The first run after this will prompt for permissions one more time;
subsequent rebuilds re-signed with the same cert will keep them.

### Developer ID

If you have an Apple Developer account, sign with your Developer ID
instead — same effect as a self-signed cert, plus the binary will work
on machines other than yours:

```sh
codesign --sign "Developer ID Application: …" --options runtime --force --deep go_fish.app
```

After switching signing identities (ad-hoc → self-signed, self-signed →
Developer ID, etc.), you'll need to remove the old go_fish entry from
System Settings → Privacy & Security → Accessibility (and Screen
Recording) once.

## Project layout

```
go_fish/
├── README.md
├── build.sh               # compiles ./src → ./go_fish.app; ad-hoc signs.
│                          #   No auto-launch by default — that's opt-in via the
│                          #   "Start at boot" menu item once go_fish is running
├── go_fish.app            # the built bundle (produced by build.sh)
├── docs/
│   ├── BUILDING.md
│   └── USAGE.md
└── src/
    ├── Info.plist         # bundle metadata (CFBundleExecutable, LSUIElement, icon)
    ├── main.m             # entry point, permission preflight with 3-attempt
    │                      #   backoff (attempts.txt), runs NSApp
    ├── switcher.h         # declares the switcher event entry points
    ├── switcher.m         # switcher state machine: gfOnHotkey / gfOnCommit /
    │                      #   gfOnCancel / gfSetSelection / gfOnClose
    ├── cocoa.h            # C interface exposed by cocoa.m (gf_* functions)
    ├── cocoa.m            # Cocoa: event tap, parallelized AX enumeration,
    │                      #   panel UI, status item + menu (Show / Minimize /
    │                      #   Cascade / Start at boot / SEI detection / Quit),
    │                      #   MRU, thumbnail cache, activation, close, bulk
    │                      #   minimize / cascade, Login Items install/uninstall,
    │                      #   Secure Event Input poller + red-X icon overlay
    └── hook.png           # menu-bar icon, embedded via xxd-generated hook_png.h
```

### Internal surface (cocoa.h / switcher.h)

The program is one Objective-C target split across three translation units.
The seam between the switcher state machine (`switcher.m`) and the Cocoa layer
(`cocoa.m`) is a small C surface worth knowing if you're editing either side:

- `switcher.h` — the five event entry points `cocoa.m` calls when the user
  acts: `gfOnHotkey`, `gfOnCommit`, `gfOnCancel`, `gfSetSelection`,
  `gfOnClose`. They own the live window list and the selected index.
- `cocoa.h` — the `gf_*` functions `switcher.m` and `main.m` call to drive the
  UI and query window state:

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
- `gf_isLoginItemInstalled()` / `gf_installLoginItem()` /
  `gf_uninstallLoginItem()` — backing the **Start at boot** menu
  toggle. They add/remove the enclosing `.app` bundle in the per-user
  Login Items list via the `LSSharedFileList` session list. The target
  is derived from `_NSGetExecutablePath()` (resolved through `realpath`):
  if the executable sits at `<X>.app/Contents/MacOS/<exe>`, the bundle
  root `<X>.app` is registered so it launches with no Terminal window;
  run loose (a bare binary, not via `build.sh`), it falls back to the
  bare executable.
  Matching is by resolved path, so a stale entry for a different location
  reports as not installed. Effective on next login; the current instance
  is left running.

The menu-bar icon is embedded into the binary at build time: `build.sh`
runs `xxd -i hook.png` to produce `hook_png.h` (a `hook_png[]` byte array),
which `main.m` includes and hands to `gf_run`. The resulting executable is
fully self-contained — no asset files ship alongside it. To swap the icon,
replace `hook.png` and rebuild. `cocoa.m` handles both source styles:

- **Transparent-background** images (PNG with alpha) — used as-is; the
  alpha channel already encodes the silhouette.
- **Opaque-background** images (JPEG, black-on-white) — `cocoa.m` maps
  luminance to alpha so the bright background becomes transparent.

In either case the result is set as a `template` `NSImage`, so AppKit
recolors it automatically for light/dark menu bars and click highlight.

`main()` runs on the process's main OS thread by definition, which is where
Cocoa's main run loop must live — so `gf_run()` simply takes over that thread
(via `[NSApp run]`) for the lifetime of the app. (The Go version needed an
explicit `runtime.LockOSThread()` for this; the C version gets it for free.)
