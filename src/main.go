package main

/*
#cgo CFLAGS: -x objective-c -fobjc-arc -Wno-deprecated-declarations
#cgo LDFLAGS: -framework Cocoa -framework ApplicationServices -framework CoreGraphics
#include "cocoa.h"
*/
import "C"

import (
	_ "embed"
	"fmt"
	"os"
	"runtime"
	"unsafe"
)

//go:embed hook.png
var menuIcon []byte

func init() {
	// Cocoa's main run loop has to live on the OS main thread.
	runtime.LockOSThread()
}

func main() {
	if C.gf_hasAccessibility() == 0 {
		fmt.Fprintln(os.Stderr, "go-fish needs Accessibility permission.")
		fmt.Fprintln(os.Stderr, "Grant it in System Settings > Privacy & Security > Accessibility, then re-run.")
		C.gf_promptAccessibility()
		os.Exit(1)
	}
	if C.gf_hasScreenRecording() == 0 {
		fmt.Fprintln(os.Stderr, "go-fish needs Screen Recording permission for window thumbnails.")
		fmt.Fprintln(os.Stderr, "Grant it in System Settings > Privacy & Security > Screen Recording, then re-run.")
		C.gf_promptScreenRecording()
		os.Exit(1)
	}
	fmt.Fprintln(os.Stderr, "go-fish running. Press Cmd+Tab to switch windows, or click the hook in the menu bar.")
	fmt.Fprintln(os.Stderr, "If the system switcher opens instead of go-fish, disable Cmd+Tab in")
	fmt.Fprintln(os.Stderr, "System Settings > Keyboard > Keyboard Shortcuts > Mission Control.")
	C.gf_run(unsafe.Pointer(&menuIcon[0]), C.int(len(menuIcon))) // blocks; NSApplication.run
}
