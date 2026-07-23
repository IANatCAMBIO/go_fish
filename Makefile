APP     := go_fish.app
BIN     := $(APP)/Contents/MacOS/go_fish
ICNS    := $(APP)/Contents/Resources/AppIcon.icns
PLIST   := $(APP)/Contents/Info.plist
HOOK_H  := src/hook_png.h

SRCS    := src/main.m src/cocoa.m src/switcher.m
CFLAGS  := -fobjc-arc -Wall -Wno-deprecated-declarations -O2
FWORKS  := -framework Cocoa \
           -framework ApplicationServices \
           -framework CoreGraphics \
           -framework CoreServices

.PHONY: all clean run

all: $(APP)

# Top-level phony depends on the binary, plist, and icon.
$(APP): $(BIN) $(PLIST) $(ICNS)
	codesign --force --deep --sign - $@ 2>/dev/null || true
	@echo "Built $@"
	@echo "Run with: open $@   (or: ./$(BIN) for console logs)"
	@echo "Note: if keyboard shortcuts stop working after a rebuild, re-grant"
	@echo "      Accessibility in System Settings > Privacy & Security > Accessibility"
	@echo "      then quit and reopen go_fish."

# Compile all three translation units in one clang invocation.
# Depends on generated hook_png.h and all ObjC sources.
$(BIN): $(SRCS) $(HOOK_H) | $(APP)/Contents/MacOS
	clang $(CFLAGS) $(FWORKS) $(SRCS) -o $@

# Bundle directories are created as order-only prerequisites.
$(APP)/Contents/MacOS $(APP)/Contents/Resources:
	mkdir -p $@

# Info.plist is just a copy from src/.
$(PLIST): src/Info.plist | $(APP)/Contents
	mkdir -p $(APP)/Contents
	cp $< $@

# Embed hook.png as a C byte array (hook_png[] / hook_png_len).
# xxd must run from src/ so the symbol is named from the bare filename.
$(HOOK_H): src/hook.png
	( cd src && xxd -i hook.png > hook_png.h )

# Build the .icns from hook.png via a temporary .iconset.
$(ICNS): src/hook.png | $(APP)/Contents/Resources
	$(eval ICONSET := $(shell mktemp -d)/AppIcon.iconset)
	mkdir -p $(ICONSET)
	sips -z 16   16   src/hook.png --out $(ICONSET)/icon_16x16.png      >/dev/null
	sips -z 32   32   src/hook.png --out $(ICONSET)/icon_16x16@2x.png   >/dev/null
	sips -z 32   32   src/hook.png --out $(ICONSET)/icon_32x32.png      >/dev/null
	sips -z 64   64   src/hook.png --out $(ICONSET)/icon_32x32@2x.png   >/dev/null
	sips -z 128  128  src/hook.png --out $(ICONSET)/icon_128x128.png    >/dev/null
	sips -z 256  256  src/hook.png --out $(ICONSET)/icon_128x128@2x.png >/dev/null
	sips -z 256  256  src/hook.png --out $(ICONSET)/icon_256x256.png    >/dev/null
	sips -z 512  512  src/hook.png --out $(ICONSET)/icon_256x256@2x.png >/dev/null
	sips -z 512  512  src/hook.png --out $(ICONSET)/icon_512x512.png    >/dev/null
	sips -z 1024 1024 src/hook.png --out $(ICONSET)/icon_512x512@2x.png >/dev/null
	iconutil -c icns $(ICONSET) -o $@
	rm -rf $(shell dirname $(ICONSET))

run: all
	open $(APP)

clean:
	rm -rf $(APP) $(HOOK_H)
