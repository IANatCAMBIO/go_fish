APP       := go_fish.app
BIN       := $(APP)/Contents/MacOS/go_fish
ICNS      := $(APP)/Contents/Resources/AppIcon.icns
PLIST     := $(APP)/Contents/Info.plist
HOOK_H    := src/hook_png.h
CERT_NAME := go_fish Dev

SRCS    := src/main.m src/cocoa.m src/switcher.m
CFLAGS  := -fobjc-arc -Wall -Wno-deprecated-declarations -O2
FWORKS  := -framework Cocoa \
           -framework ApplicationServices \
           -framework CoreGraphics \
           -framework CoreServices

.PHONY: all clean run cert

all: $(APP)

# Create a stable self-signed code-signing certificate in the login keychain.
# Run once: after this, Accessibility permissions survive every rebuild.
# On first use codesign may show "wants to use keychain" — click Always Allow.
cert:
	@if security find-identity -v -p codesigning 2>/dev/null | grep -q '"$(CERT_NAME)"'; then \
		echo "Certificate '$(CERT_NAME)' already exists — nothing to do."; \
	else \
		echo "Creating local code-signing certificate '$(CERT_NAME)'..."; \
		T=$$(mktemp -d); \
		printf '[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=$(CERT_NAME)\n[ext]\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' > $$T/cfg; \
		openssl req -new -x509 -newkey rsa:2048 -nodes \
			-keyout $$T/key.pem -out $$T/cert.pem \
			-days 3650 -config $$T/cfg 2>/dev/null; \
		openssl pkcs12 -export \
			-inkey $$T/key.pem -in $$T/cert.pem \
			-out $$T/cert.p12 -passout pass:gofish \
			-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 2>/dev/null; \
		security import $$T/cert.p12 \
			-k ~/Library/Keychains/login.keychain-db \
			-P 'gofish' -T /usr/bin/codesign; \
		security add-trusted-cert -r trustRoot -p codeSign \
			-k ~/Library/Keychains/login.keychain-db $$T/cert.pem; \
		rm -rf $$T; \
		echo "Done. Rebuild the app to use it."; \
	fi

# Top-level phony depends on the binary, plist, and icon.
# Signs with the stable local cert if it exists; falls back to ad-hoc and
# reminds the user to run 'make cert' once if they want permissions to persist.
$(APP): $(BIN) $(PLIST) $(ICNS)
	@if security find-identity -v -p codesigning 2>/dev/null | grep -q '"$(CERT_NAME)"'; then \
		codesign --force --deep --sign "$(CERT_NAME)" $@; \
	else \
		codesign --force --deep --sign - $@ 2>/dev/null || true; \
		echo "Tip: run 'make cert' once so Accessibility permissions survive rebuilds."; \
	fi
	@echo "Built $@"
	@echo "Run with: open $@   (or: ./$(BIN) for console logs)"

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
