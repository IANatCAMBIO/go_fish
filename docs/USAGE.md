# Using go-fish

go-fish replaces the default macOS Cmd+Tab application switcher with a grid
of window thumbnails — every window of every regular app, including
minimized ones, each addressable individually.

## First run

```sh
./go-fish
```

On the first launch, go-fish needs two permissions and will exit with a
message after each. Grant them in **System Settings → Privacy & Security**:

1. **Accessibility** — required to read each app's window list, raise
   windows, un-minimize them, and intercept Cmd+Tab via a global event tap.
2. **Screen Recording** — required to capture live thumbnails of windows.
   Without it, every tile falls back to the app icon (the program still
   works, just less informative).

After granting both, run `./go-fish` again. You should see:

```
go-fish running. Press Cmd+Tab to switch windows, or click the hook in the menu bar.
If the system switcher opens instead of go-fish, disable Cmd+Tab in
System Settings > Keyboard > Keyboard Shortcuts > Mission Control.
```

A fishing-hook icon appears in the right side of the menu bar while
go-fish is running. Click it to drop down a menu:

- **Show Window Grid** — opens the all-apps grid (same as Cmd+Tab).
- **Minimize All** — minimizes every standard window of every regular
  app. Windows already minimized are skipped.
- **Cascade All** — un-minimizes minimized windows, resizes each to
  ~75% of the visible screen area (clamped to 480×320 / 1600×1000), and
  arranges them in a staircase on the screen under the cursor. The
  cascade runs back-to-front, so the bottom-most window lands at the
  top-left and every window's title bar stays visible. Apps that refuse
  AX position writes (fixed-UI Electron tools, full-screen apps that
  don't expose `AXFullScreen`, etc.) are skipped silently; the log file
  (`~/Library/Logs/go-fish.err.log`) records which.
- **Quit** — terminates go-fish. The keyboard shortcut listed beside it
  (⌘Q) only works while the menu is open; there's no key window
  otherwise.

## Disable the conflicting system shortcuts

macOS has two built-in shortcuts that fire inside WindowServer **before**
any third-party event tap can see them. Both need to be off for go-fish
to receive the keystrokes reliably:

1. **Cmd+Tab** (system app switcher) → **System Settings → Keyboard →
   Keyboard Shortcuts → Mission Control**, find the entry bound to ⌘⇥
   ("application switcher" / "Move focus to next window" depending on
   macOS version), and uncheck it or rebind it.

2. **Cmd+\`** (system "Move focus to next window") → **System Settings →
   Keyboard → Keyboard Shortcuts → Keyboard**, find "Move focus to next
   window in active app" bound to ⌘\`, and uncheck it.

You can leave either binding enabled if you only want one of the two
go-fish shortcuts — they're independent. If a shortcut doesn't seem to
trigger go-fish, the system binding is the first thing to check.

## Using the switcher

| Action                          | Result                                             |
| ------------------------------- | -------------------------------------------------- |
| **Cmd + Tab**                   | Open the grid with every app's windows; pre-select the next-most-recent |
| **Cmd + \`**                    | Open the grid filtered to the **current app**'s windows only |
| **Click the menu-bar hook → "Show Window Grid"** | Open the grid (all apps; no Cmd needed; commit by clicking a tile) |
| **Tab** (while Cmd held)        | Cycle forward                                      |
| **Shift + Tab** (while grid is open) | Cycle backward                                |
| **Move mouse over a tile**      | Hover-select: the selection follows the cursor     |
| **Click a tile**                | Select that tile and commit immediately            |
| **Click the X on a tile**       | Close that window (AX-press its close button); the tile drops out of the grid without dismissing the panel |
| **Release Cmd**                 | Commit: focus the selected window                  |
| **Escape**                      | Cancel: close the grid, do nothing                 |

Cmd+\` always shows the grid, even if the current app has just one
window — useful for confirming what's open without context-switching.

Keyboard and mouse can be mixed freely: hover changes the selection that
Cmd-release would commit to, and a click bypasses the Cmd-release step
entirely (so you don't even need to be holding Cmd anymore once the grid
is up).

When you commit:

- If the chosen window is **minimized**, go-fish un-minimizes it (restoring
  it to its last size and position) and brings it to the front.
- If the chosen window is on **another Space or another display**, macOS
  automatically switches to that Space as a side-effect of activating the
  owning app.
- If the chosen window is **already frontmost**, nothing visible happens —
  same as native Cmd+Tab.

## What appears in the grid

Every "standard" window of every running app whose activation policy is
*regular* (i.e. apps that show up in the Dock). This includes:

- Visible windows on the current Space
- Windows on other Spaces / other displays
- Minimized windows (shown with their app icon and a small "minimized"
  badge, since no live image is available)
- One placeholder per **unresponsive app** — apps that don't reply to
  the AX windows query within 100 ms. The placeholder uses the app icon,
  shows a red "not responding" badge, dims the tile to 70%, and omits
  the X button (we can't reliably close a specific window through an
  app that isn't talking back). Clicking the tile still activates the
  app via `NSRunningApplication`, which usually unsticks it.

It excludes palettes, system dialogs, menu-bar–only apps, the Dock, etc.

### Tile anatomy

Each tile shows, top to bottom:

- The **app name** (bold, centered), with an **X close button** to its
  left in the same horizontal band.
- The **thumbnail** (live capture for visible windows; app icon for
  minimized or just-snapshotted ones). A "minimized" or "not responding"
  badge overlays the top-left when applicable.
- The **window title** (or the app name as a fallback when the window
  has no title).

The selected tile is wrapped in a translucent accent-colored highlight
that follows the keyboard or mouse selection.

Windows are ordered **most-recently-used first**, so:

- Position 1 (the one pre-selected when the grid opens) is always the window
  you were on just before the current one. A quick Cmd+Tab — press and
  release without cycling — toggles between the last two windows you used.
- Repeated quick Cmd+Tabs ping-pong between those two, the same way native
  Cmd+Tab does for apps.
- Windows you've focused at any point during this go-fish session are
  ordered by recency; windows that haven't been touched fall back to
  z-order, then off-Space, then minimized at the very end.

MRU is rebuilt in memory each time go-fish starts (seeded from the current
z-order) and updated by listening to `NSWorkspaceDidActivateApplication`
notifications plus per-app `kAXFocusedWindowChangedNotification`
observers, so within-app window switches (clicking another window,
in-app Cmd+\`, etc.) also register.

## Configuration

For now go-fish has no config file — the hotkey is fixed at **Cmd+Tab** by
design (it's the slot you've chosen to replace). Future configuration
points, if you want them:

| Setting              | Where to change in source                  | Default                  |
| -------------------- | ------------------------------------------ | ------------------------ |
| Trigger keycode      | `cocoa.m` → `tapCallback` `0x30`           | Tab                      |
| Trigger modifier     | `cocoa.m` → `kCGEventFlagMaskCommand`      | Cmd                      |
| Tile size            | `cocoa.m` → `gf_preferredPanelSize` `tileW`| 240pt wide tiles         |
| Panel clamp          | `cocoa.m` → `gf_showPanel` `maxW`/`maxH`   | 90% × 85% of screen      |
| Per-app AX timeout   | `cocoa.m` → `kAXAppTimeout`                | 0.1 s                    |
| Thumbnail cache cap  | `cocoa.m` → `kThumbCap`                    | 30 entries               |
| Thumbnail stale-after| `cocoa.m` → `kThumbStaleAfter`             | 30 s                     |
| Cascade offset       | `cocoa.m` → `gf_cascadeAll` `offset`       | 32pt                     |
| Cascade target size  | `cocoa.m` → `gf_cascadeAll` `targetW/H`    | 75% of vf, clamped       |

To rebuild after editing, see `BUILDING.md`.

## Running in the background, always

go-fish runs as an accessory app (no Dock icon by default; only the menu-bar
hook) and idles at effectively zero CPU until you press the hotkey. To start
it automatically on login, use a per-user `LaunchAgent`.

### Easy path: `install.sh`

The repo includes a zsh installer that does everything for you:

```sh
./install.sh              # install the prebuilt binary at ./bin/go-fish
./install.sh --build      # compile ./src → ./bin/go-fish first (needs Go + Xcode CLT)
./install.sh uninstall    # stop and remove
```

The default install path expects a prebuilt `./bin/go-fish` (which the
repo ships with) so the target machine doesn't need a Go toolchain. If
you do have Go installed and want to rebuild from source as part of the
install, pass `--build` — that compiles inside `./src/` and writes the
output back to `./bin/go-fish`.

It ad-hoc signs the local binary (so the Accessibility / Screen
Recording grants survive future rebuilds when you re-run this script),
copies it to `/usr/local/bin/go-fish` (prompting for sudo once), drops a
plist into `~/Library/LaunchAgents/`, and loads it. Re-running is safe —
it unloads the previous version first.

### Manual path

If you'd rather wire it up by hand, create
`~/Library/LaunchAgents/com.local.gofish.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.local.gofish</string>

    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/go-fish</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>ProcessType</key>
    <string>Interactive</string>

    <key>StandardErrorPath</key>
    <string>/Users/YOUR_USERNAME/Library/Logs/go-fish.err.log</string>

    <key>StandardOutPath</key>
    <string>/Users/YOUR_USERNAME/Library/Logs/go-fish.out.log</string>
</dict>
</plist>
```

Then:

```sh
launchctl load -w ~/Library/LaunchAgents/com.local.gofish.plist
```

Stop or unload with:

```sh
launchctl unload ~/Library/LaunchAgents/com.local.gofish.plist
```

## Resource footprint

- Idle: a few tens of MB resident, ~0% CPU. The only ongoing background
  work is an event tap waiting for keystrokes via `CFRunLoop`, plus
  occasional thumbnail re-captures triggered by focus/activation events
  (a single `CGWindowListCreateImage` per event, ~10–30 ms each).
- Per activation: one round of AX enumeration plus, if the cache is hit,
  zero capture work — thumbnails appear instantly.
- A thumbnail cache holds up to 30 recently-focused windows (LRU,
  ~25–30 MB at the cap). It's pre-warmed at startup (visible windows are
  captured serially over a few seconds at utility priority) and refreshed
  whenever a window gets focused, an app gets activated, or you activate
  a window via go-fish itself. Cached entries older than 30 s get
  re-captured in the background when the grid opens — the stale version
  is still displayed instantly while the refresh runs.
- Window list is **not** maintained in memory between activations; it's
  snapshotted on demand.

## Troubleshooting

### Cmd+Tab still opens the system switcher

WindowServer's built-in shortcut is taking the key before go-fish sees it.
Disable it (see "Disable the system Cmd+Tab" above).

### Panel doesn't appear, but the system one is disabled

- Confirm Accessibility permission is granted (System Settings → Privacy
  & Security → Accessibility). The toggle must be **on** for `go-fish`.
- If you re-signed or rebuilt the binary, macOS may consider it a new app
  and silently revoke the permission until you re-grant it.
- Check `/tmp/go-fish.err.log` if running under a LaunchAgent.

### Thumbnails are missing / all entries show app icons

Grant Screen Recording permission. After granting, you must quit and
re-launch go-fish — macOS only re-checks the permission at process start.

### A window appears in the grid that I can't activate

Some sandboxed apps return AX window elements that don't accept
`kAXRaiseAction`. go-fish will still call `activateWithOptions:` on the
owning app, which usually brings *some* window of that app forward but may
not be the exact one you selected. Known offender: certain Electron apps
in unusual states.

### An app shows up as "not responding"

The app didn't reply to go-fish's AX windows query within the per-app
budget (100 ms by default — see `kAXAppTimeout` in `cocoa.m`). The most
common causes are an app stuck waiting on disk/network, mid-launch
initialization, or an in-progress modal that hasn't fully realized. The
placeholder tile lets you still bring the app forward — clicking it
calls `activateWithOptions:` on the process, which often unsticks the
event loop. If you want to be more aggressive: right-click the Dock icon
and choose Force Quit, or `kill <pid>` from a shell.

### Cascade All didn't move some windows

`Cascade All` writes `kAXPositionAttribute` on each window, but some apps
refuse position writes (fixed-UI tools, full-screen apps that don't
expose `AXFullScreen`, certain Electron apps). Skipped windows are
logged to `~/Library/Logs/go-fish.err.log` with their app name and the
AX error code; a summary line at the end reports `moved N, resized M,
skipped K of T`. Full-screen apps are best-effort un-fullscreened first
(via the undocumented `AXFullScreen` attribute) — works for Safari,
Mail, most Apple apps; not for every third-party.

### After granting permissions, it still complains

Permissions are tied to the binary's signing identity. For an ad-hoc
signed binary (what `install.sh` produces by default), that identity is
the **CDHash** — a hash of the binary's bytes. Every rebuild produces
different bytes, so a fresh CDHash, so macOS treats it as a new app and
re-prompts.

The System Settings UI shows one entry per path, so you'll see the
go-fish row still toggled **on** — but that's the previous CDHash's
grant. The OS is waiting on permission for the current binary.

**To fix once:** in **System Settings → Privacy & Security → Accessibility**,
select the go-fish row and click the **−** button to remove it entirely.
Do the same under **Screen Recording**. Re-run `./install.sh`. The next
prompt will create a fresh entry that matches the running binary, and
it'll stick until the next rebuild.

**To stop the cycle:** stop using ad-hoc signing. Either
(a) install once and don't rebuild, or
(b) sign with a stable identity (Developer ID, or a self-signed code-
signing cert you create in Keychain Access). See `BUILDING.md` →
*Code signing* for both options.
