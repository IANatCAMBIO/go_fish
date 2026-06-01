# go_fish — pure Objective-C build (no Go toolchain).
#
# Outputs ../bin/go_fish. The menu-bar icon (hook.png) is embedded as a C byte
# array via xxd so the binary stays self-contained (no bundle / resources).

BIN        := ../bin/go_fish
SRCS       := main.m cocoa.m switcher.m
GEN        := hook_png.h
CC         := clang
CFLAGS     := -fobjc-arc -Wall -Wno-deprecated-declarations -O2
FRAMEWORKS := -framework Cocoa \
              -framework ApplicationServices \
              -framework CoreGraphics \
              -framework CoreServices

.PHONY: all clean
all: $(BIN)

# Embed hook.png as hook_png[] / hook_png_len. Run from this dir so xxd derives
# the symbol name from the bare filename.
$(GEN): hook.png
	xxd -i hook.png > $(GEN)

$(BIN): $(SRCS) $(GEN) cocoa.h switcher.h
	@mkdir -p ../bin
	$(CC) $(CFLAGS) $(SRCS) $(FRAMEWORKS) -o $(BIN)

clean:
	rm -f $(BIN) $(GEN)
