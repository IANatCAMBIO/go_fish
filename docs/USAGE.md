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
go-fish is running. Click it to drop down a menu with two items:

- **Show Window Grid** — opens the all-apps grid (same as Cmd+Tab).
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

It excludes palettes, system dialogs, menu-bar–only apps, the Dock, etc.

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

| Setting          | Where to change in source           | Default               |
| ---------------- | ----------------------------------- | --------------------- |
| Trigger keycode  | `cocoa.m` → `tapCallback` `0x30`    | Tab                   |
| Trigger modifier | `cocoa.m` → `kCGEventFlagMaskCommand` | Cmd                 |
| Tile size        | `cocoa.m` → `GFPanelView.drawRect`  | 200pt wide tiles      |
| Panel dimensions | `cocoa.m` → `ensurePanel`           | 85% × 70% of main screen |

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

### After granting permissions, it still complains

Permissions are tied to the binary's signing identity. If the binary is
unsigned, every rebuild looks like a new app to macOS. See the
"Code signing" section of `BUILDING.md` to ad-hoc sign the binary, which
gives it a stable identifier across rebuilds.
