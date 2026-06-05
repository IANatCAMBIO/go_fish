#!/bin/bash
# Builds go_fish.app from the Objective-C sources in src/.
#
# go_fish is a menubar window switcher (a per-window Cmd+Tab replacement).
# Shipping it as a .app bundle is what lets the "Start at boot" toggle launch
# it at login with NO Terminal window — a bare Unix binary in Login Items has
# no LaunchServices opener, so macOS hosts it in Terminal.app instead.
#
# Output: ./go_fish.app in the repo root. Run it with `open go_fish.app`.
set -euo pipefail

cd "$(dirname "$0")"

APP="go_fish.app"
MACOS_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"
BIN="$MACOS_DIR/go_fish"

rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$RES_DIR"

# Embed the menu-bar icon (hook.png) as a C byte array (hook_png[] /
# hook_png_len) so the binary carries it with no resource lookup. main.m
# #includes "hook_png.h"; xxd must run from src/ so the symbol name is derived
# from the bare filename rather than a path.
( cd src && xxd -i hook.png > hook_png.h )

# Compile the three translation units into the bundle's executable.
clang -fobjc-arc -Wall -Wno-deprecated-declarations -O2 \
    -framework Cocoa \
    -framework ApplicationServices \
    -framework CoreGraphics \
    -framework CoreServices \
    src/main.m src/cocoa.m src/switcher.m \
    -o "$BIN"

# Bundle metadata (CFBundleExecutable, LSUIElement, icon ref, etc.).
cp src/Info.plist "$APP/Contents/Info.plist"

# Build the app icon from the same hook.png the menu bar uses: sips renders the
# ten required sizes into an .iconset, iconutil packs them into AppIcon.icns.
# (The hook is a transparent black silhouette — crisp on light backgrounds,
# faint on dark ones. Swap in a backed PNG if you want more contrast.)
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
sips -z 16 16     src/hook.png --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32 32     src/hook.png --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32     src/hook.png --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64 64     src/hook.png --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128   src/hook.png --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256 256   src/hook.png --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   src/hook.png --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512 512   src/hook.png --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   src/hook.png --out "$ICONSET/icon_512x512.png"    >/dev/null
sips -z 1024 1024 src/hook.png --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$RES_DIR/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

# Ad-hoc sign so macOS lets it run and request Accessibility / Screen Recording.
# --deep covers the Resources. Re-signing changes the code identity, so macOS
# re-prompts for those permissions after each build.
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "Built $APP"
echo "Run with: open $APP   (or: ./$BIN for console logs)"
