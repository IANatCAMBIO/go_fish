# Building go_fish

## Requirements

- macOS 12 or later (`LSMinimumSystemVersion` is 12.0); developed and tested on
  macOS 26, arm64
- Xcode Command Line Tools (`xcode-select --install`) — provides clang, `xxd`,
  `sips`, `iconutil`, `codesign`, and the macOS SDK
- No third-party dependencies: the build is pure Objective-C against system
  frameworks

## Build

Source code lives under `src/`. The `Makefile` in the repo root drives
everything:

| Target        | What it does                                                     |
| ------------- | ---------------------------------------------------------------- |
| `make`        | Compile `./src` → `./go_fish.app` and sign it (the default target) |
| `make run`    | `make`, then `open go_fish.app`                                  |
| `make cert`   | One-time: create the local signing cert so permissions survive rebuilds |
| `make test`   | Build and run the switcher state-machine tests                   |
| `make clean`  | Remove `go_fish.app`, the generated `hook_png.h`, and `build/`   |

```sh
make                     # compiles ./src → ./go_fish.app
open go_fish.app         # or: make run
```

The build does four things:

1. Generates `src/hook_png.h` from `src/hook.png` via `xxd -i` — the embedded
   menu-bar icon, as a `hook_png[]` byte array.
2. Compiles `main.m`, `cocoa.m`, and `switcher.m` in a **single** clang
   invocation to `go_fish.app/Contents/MacOS/go_fish` (~210 KB, arm64).
3. Assembles the rest of the bundle: `Contents/Info.plist` (copied from
   `src/Info.plist`) and `Contents/Resources/AppIcon.icns`. The icon is built
   from the *same* `hook.png` the menu bar uses — `sips` renders the ten
   required sizes into a temporary `.iconset` and `iconutil` packs them into
   `AppIcon.icns` (referenced via `CFBundleIconFile` in the plist). Because the
   hook is a transparent black silhouette it reads well on light backgrounds
   and faintly on dark ones — swap in a backed PNG if you want more contrast.
4. Signs the bundle — with the local `go_fish Dev` certificate if `make cert`
   has been run, otherwise ad-hoc. See [Code signing](#code-signing); the
   difference decides whether your Accessibility grant survives the rebuild.

The bundle (rather than a bare binary) is what makes go_fish launch as a Login
Item with no Terminal window; see
[USAGE.md](USAGE.md#auto-launch-on-login-start-at-boot).

The build is incremental against real prerequisites: touching any source
recompiles the executable and re-signs, but skips the icon and plist steps.
Since all three translation units go through one clang call, editing any one of
them recompiles all three. `hook_png.h` is generated into `src/` and is
gitignored. Use `make clean` for a from-scratch rebuild.

For console logs, run the executable inside the bundle directly instead of
using `open`:

```sh
./go_fish.app/Contents/MacOS/go_fish
```

### What it links against

The `FWORKS` variable in the `Makefile` lists these system frameworks:

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

`CFLAGS` passes `-Wno-deprecated-declarations` because both the `dlsym`'d
capture path and the `LSSharedFileList` login-item calls are formally
deprecated but still functional. (`SMAppService` is the modern login-item
API and would work now that go_fish ships as a bundle, but `LSSharedFileList`
remains in place as the lighter-touch change.)

## Tests

```sh
make test
```

`test/switcher_test.m` exercises the switcher state machine in
`src/switcher.m`. It links that file against **stub** `gf_*` backend functions
defined in the test itself — it deliberately does not link `cocoa.m` — so the
tests need no Accessibility permission, no window server, no built bundle, and
have no side effects on your desktop. The binary lands in `build/`.

The stub for `gf_enumerateWindowsAsync` parks the completion block instead of
dispatching it, which lets a test decide exactly when an in-flight window
snapshot "arrives". That is the point of the suite: since enumeration moved off
the main thread, there is an interval where the switcher is neither open nor
closed, and the orderings that land inside it (hotkey released before the
snapshot arrives, Escape before it arrives, extra Tab presses before it
arrives, a stale snapshot racing a live one) are the ones worth pinning down.
They were unreachable while enumeration blocked the main thread.

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

clang produces a universal binary directly — add both arches to the compile
flags. No need to edit the `Makefile`; a command-line variable overrides the
assignment inside it:

```sh
make clean
make CFLAGS="-fobjc-arc -Wall -Wno-deprecated-declarations -O2 -arch arm64 -arch x86_64"
```

To make it the permanent default, append `-arch arm64 -arch x86_64` to the
`CFLAGS :=` line in the `Makefile` instead.

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

### Stable identity via `make cert` (recommended)

Run this **once** per machine:

```sh
make cert
```

It creates a self-signed code-signing certificate named `go_fish Dev`,
imports it into your login keychain, and marks it trusted for code signing —
the same result as walking through Keychain Access → Certificate Assistant,
without the clicking. On first use `codesign` may ask to use the keychain;
choose **Always Allow**.

From then on every `make` detects the certificate and signs with it, so the
Accessibility and Screen Recording grants persist across rebuilds. `make cert`
is idempotent — if the certificate already exists it reports that and does
nothing.

Rebuild once after creating the cert. That run changes the signing identity,
so macOS will prompt for permissions one final time; subsequent rebuilds keep
them.

### Without a certificate

If `go_fish Dev` is absent, `make` falls back to an ad-hoc signature and prints
a reminder. This needs no setup, but **every rebuild re-prompts** for
Accessibility and Screen Recording, because the CDHash changes with the
content. The symptom is documented in `USAGE.md` → *After granting
permissions, it still complains*.

### Developer ID

If you have an Apple Developer account, sign with your Developer ID instead —
same effect as the self-signed cert, plus the binary will work on machines
other than yours:

```sh
codesign --sign "Developer ID Application: …" --options runtime --force --deep go_fish.app
```

After switching signing identities (ad-hoc → self-signed, self-signed →
Developer ID, etc.), remove the old go_fish entry from System Settings →
Privacy & Security → Accessibility (and Screen Recording) once.

## Project layout

```
go_fish/
├── README.md
├── Makefile               # build / sign / cert / run / test / clean
│                          #   No auto-launch by default — that's opt-in via the
│                          #   "Start at boot" toggle in Settings once go_fish runs
├── go_fish.app            # the built bundle (produced by make)
├── build/                 # test binaries (make clean removes)
├── docs/
│   ├── BUILDING.md
│   └── USAGE.md
├── test/
│   └── switcher_test.m    # switcher state machine vs. stub gf_* backend
└── src/
    ├── Info.plist         # bundle metadata (CFBundleExecutable, LSUIElement, icon)
    ├── main.m             # entry point, permission preflight with 3-attempt
    │                      #   backoff (attempts.txt), runs NSApp
    ├── switcher.h         # declares the switcher event entry points
    ├── switcher.m         # switcher state machine: gfOnHotkey / gfOnCommit /
    │                      #   gfOnCancel / gfSetSelection / gfOnClose /
    │                      #   gfOnFocus / gfToggleSort
    ├── cocoa.h            # C interface exposed by cocoa.m (gf_* functions)
    ├── cocoa.m            # Cocoa: event tap, parallelized AX enumeration,
    │                      #   panel UI, status item + menu (Show Window Grid /
    │                      #   Minimize All / Cascade All / Settings… / Quit),
    │                      #   settings window (hotkey, quick-switch delay,
    │                      #   Start at boot, SEI detection, grid toggles,
    │                      #   title overrides), MRU,
    │                      #   thumbnail cache, activation, close, bulk minimize /
    │                      #   cascade, Login Items install/uninstall,
    │                      #   Secure Event Input poller + red-X icon overlay
    └── hook.png           # menu-bar icon, embedded via xxd-generated hook_png.h
```

### Internal surface (cocoa.h / switcher.h)

The program is one Objective-C target split across three translation units.
The seam between the switcher state machine (`switcher.m`) and the Cocoa layer
(`cocoa.m`) is a small C surface worth knowing if you're editing either side:

- `switcher.h` — the event entry points `cocoa.m` calls when the user acts:
  `gfOnHotkey`, `gfOnCommit`, `gfOnCancel`, `gfSetSelection`, `gfOnClose`,
  `gfOnFocus`, `gfToggleSort`. They own the live window list and the selected
  index. All are called on the main thread, and none of them block on window
  enumeration — `gfOnHotkey` starts the snapshot and returns.
- `cocoa.h` — the `gf_*` functions `switcher.m` and `main.m` call to drive the
  UI and query window state:

- `gf_enumerateWindowsAsync(filterPID, done)` — the snapshot call used on the
  hotkey path. Runs the AX fan-out off the main thread and invokes `done` back
  on the main queue, handing over ownership of the list. Must be *called* on
  the main thread: the snapshot opens by seeding and reading the MRU list,
  which is main-thread state. Keeping the fan-out off the main thread matters
  because the event tap's run-loop source lives there — blocking it delays the
  modifier-up that signals a quick switch, and a stalled app can hold it long
  enough for macOS to disable the tap (`kCGEventTapDisabledByTimeout`).
- `gf_enumerateWindows(out_count, filterPID)` — the blocking form, same
  main-thread requirement. Used only where blocking is already the shape of the
  operation: the bulk-arrangement actions, which then spend far longer moving
  windows than enumerating them.
- Internally both share one implementation, split in two:
  `gf_enumeratePrologue` (main-thread-only; the `CGWindowList` pass, the MRU
  seed it feeds, and an immutable MRU snapshot) and `gf_enumerateAX` (thread-
  agnostic; reads only those immutable dictionaries). `gf_enumerateAX`
  parallelizes per-app AX queries via `dispatch_apply` on the global
  `USER_INTERACTIVE` queue; each worker writes into its own pre-allocated slot
  and a single-threaded merge phase assembles the output buffer in stable app
  order, so window ordering and `fallbackZ` are identical to the pre-parallel
  implementation. Each window's three attributes (minimized, subrole, title)
  come back in one round trip via `AXUIElementCopyMultipleAttributeValues`
  rather than three. The 100 ms messaging timeout is set on the application
  element *and* on each window element — it binds to the object it is called
  on, not to the app's whole element tree, so setting it once on the app would
  leave per-window reads running at the global default. Unresponsive apps
  surface as a single `unresponsive=1` entry with `axRef=NULL`.
- `gf_activateWindow(axRef, pid, minimized, windowless)` — un-minimize + raise
  + activate. Accepts `axRef=NULL` for unresponsive placeholders (falls back to
  app-only activation via `NSRunningApplication`). With `windowless=1` it also
  sends the app a reopen Apple event, as a Dock-icon click would, so the app
  creates its default window.
- `gf_closeWindow(axRef)` — presses the window's AX close button. Caller keeps
  ownership of `axRef`.
- `gf_quitApp(pid)` — graceful terminate, used to "close" a windowless app
  placeholder, which has no window to close.
- `gf_minimizeAll()` / `gf_cascadeAll()` — menu-bar bulk actions.
- `gf_focusApp(pid)` — minimize everything not belonging to `pid`, then
  un-minimize and cascade that app's windows. Backs the per-tile `⧉` button,
  shown when *Show cascade button in grid* is enabled in Settings.
- `gf_getSortMode()` / `gf_toggleSortMode()` — grid sort order, 0 = MRU,
  1 = alphabetical by app. The toggle persists the new value and returns it.
- `gf_showPanel(data, selected)` — full panel show with resize + recenter.
  Waits out the remainder of the quick-switch window before drawing: the delay
  is measured from the hotkey *press*, so enumeration time is charged against
  it rather than added to it, subject to a small floor that keeps the panel
  from being ordered front in the same run-loop turn as a pending modifier-up.
- `gf_updatePanelEntries(data, selected)` — in-place entry refresh
  (no resize/recenter); used after closing a window so the panel
  doesn't visually jump.
- `gf_updateSelection(selected)` — fast-path selection change. Dirties
  only the previously-selected and newly-selected cells so mouse-hover
  redraws stay cheap with large grids.
- `gf_isLoginItemInstalled()` / `gf_installLoginItem()` /
  `gf_uninstallLoginItem()` — backing the **Start at boot** toggle. They
  add/remove the enclosing `.app` bundle in the per-user Login Items list via
  the `LSSharedFileList` session list. The target is derived from
  `_NSGetExecutablePath()` (resolved through `realpath`): if the executable
  sits at `<X>.app/Contents/MacOS/<exe>`, the bundle root `<X>.app` is
  registered so it launches with no Terminal window; run loose as a bare
  binary, it falls back to the bare executable.
  Matching is by resolved path, so a stale entry for a different location
  reports as not installed. Effective on next login; the current instance
  is left running.

The menu-bar icon is embedded into the binary at build time: the `Makefile`
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
