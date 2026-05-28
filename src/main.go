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
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
	"unsafe"
)

//go:embed hook.png
var menuIcon []byte

// LaunchAgent crash-loop guard. We give the permission preflight at most
// `attemptsCap` shots, with linear-ish backoff between launches (0s, 1s,
// 2s). If we're still failing after that, we exit(0) so launchd's
// SuccessfulExit=false keep-alive stops restarting us. A successful run
// (past the preflight) resets the counter.
const attemptsCap = 3

func attemptsFile() string {
	return filepath.Join(os.Getenv("HOME"),
		"Library/Application Support/go_fish/attempts.txt")
}

func readAttempts() int {
	b, err := os.ReadFile(attemptsFile())
	if err != nil {
		return 0
	}
	n, _ := strconv.Atoi(strings.TrimSpace(string(b)))
	if n < 0 {
		return 0
	}
	return n
}

func writeAttempts(n int) {
	path := attemptsFile()
	_ = os.MkdirAll(filepath.Dir(path), 0o755)
	_ = os.WriteFile(path, []byte(strconv.Itoa(n)), 0o644)
}

func init() {
	// Cocoa's main run loop has to live on the OS main thread.
	runtime.LockOSThread()
}

func main() {
	attempts := readAttempts()
	if attempts >= attemptsCap {
		fmt.Fprintf(os.Stderr,
			"go_fish: gave up after %d permission attempts. Grant Accessibility\n",
			attempts)
		fmt.Fprintln(os.Stderr,
			"and Screen Recording in System Settings > Privacy & Security, then re-launch.")
		writeAttempts(0)
		os.Exit(0)
	}
	if attempts > 0 {
		time.Sleep(time.Duration(attempts) * time.Second)
	}

	if C.gf_hasAccessibility() == 0 {
		fmt.Fprintln(os.Stderr, "go_fish needs Accessibility permission.")
		fmt.Fprintln(os.Stderr, "Grant it in System Settings > Privacy & Security > Accessibility, then re-run.")
		C.gf_promptAccessibility()
		writeAttempts(attempts + 1)
		os.Exit(1)
	}
	if C.gf_hasScreenRecording() == 0 {
		fmt.Fprintln(os.Stderr, "go_fish needs Screen Recording permission for window thumbnails.")
		fmt.Fprintln(os.Stderr, "Grant it in System Settings > Privacy & Security > Screen Recording, then re-run.")
		C.gf_promptScreenRecording()
		writeAttempts(attempts + 1)
		os.Exit(1)
	}
	writeAttempts(0)

	fmt.Fprintln(os.Stderr, "go_fish running. Press Cmd+Tab to switch windows, or click the hook in the menu bar.")
	fmt.Fprintln(os.Stderr, "If the system switcher opens instead of go_fish, disable Cmd+Tab in")
	fmt.Fprintln(os.Stderr, "System Settings > Keyboard > Keyboard Shortcuts > Mission Control.")
	C.gf_run(unsafe.Pointer(&menuIcon[0]), C.int(len(menuIcon))) // blocks; NSApplication.run
}
