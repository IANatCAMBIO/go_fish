package main

/*
#include "cocoa.h"
#include <stdlib.h>
*/
import "C"

import (
	"sort"
	"sync"
	"unsafe"
)

type winEntry struct {
	pid       int32
	axRef     unsafe.Pointer // AXUIElementRef, retained
	windowID  uint32
	title     string
	appName   string
	minimized bool
	onScreen  bool
	zOrder    int
}

var (
	mu       sync.Mutex
	active   bool
	list     []winEntry
	selected int
)

//export gfOnHotkey
// scope: 0 = all apps (Cmd+Tab), 1 = frontmost app only (Cmd+`).
func gfOnHotkey(shift C.int, scope C.int) C.int {
	mu.Lock()
	defer mu.Unlock()
	if !active {
		var filterPID C.int
		if scope == 1 {
			filterPID = C.gf_frontmostPID()
			if filterPID == 0 {
				return 0
			}
		}
		list = snapshotWindows(filterPID)
		if len(list) == 0 {
			return 0
		}
		active = true
		if len(list) > 1 {
			selected = 1
		} else {
			selected = 0
		}
		showPanel()
		return 1
	}
	if int(shift) != 0 {
		selected = (selected - 1 + len(list)) % len(list)
	} else {
		selected = (selected + 1) % len(list)
	}
	C.gf_updateSelection(C.int(selected))
	return 1
}

//export gfOnCommit
func gfOnCommit() C.int {
	mu.Lock()
	defer mu.Unlock()
	if !active {
		return 0
	}
	chosen := list[selected]
	// Transfer ownership of the chosen window's AXRef to gf_activateWindow,
	// which will CFRelease it after activating. Zero it here so tearDown skips it.
	list[selected].axRef = nil
	tearDown(false)
	C.gf_activateWindow(chosen.axRef, C.int(chosen.pid), boolC(chosen.minimized))
	return 1
}

//export gfSetSelection
func gfSetSelection(idx C.int) {
	mu.Lock()
	defer mu.Unlock()
	if !active {
		return
	}
	i := int(idx)
	if i < 0 || i >= len(list) || i == selected {
		return
	}
	selected = i
	C.gf_updateSelection(C.int(selected))
}

//export gfOnCancel
func gfOnCancel() C.int {
	mu.Lock()
	defer mu.Unlock()
	if !active {
		return 0
	}
	tearDown(true)
	return 1
}

// tearDown releases retained AX refs and clears state. Caller holds mu.
// If keepSelected is false, the chosen window's axRef is released here too;
// when committing, the caller has already copied it out before tearDown.
func tearDown(_ bool) {
	C.gf_hidePanel()
	for i := range list {
		if list[i].axRef != nil {
			C.gf_release(list[i].axRef)
		}
	}
	list = nil
	active = false
}

func snapshotWindows(filterPID C.int) []winEntry {
	var n C.int
	raw := C.gf_enumerateWindows(&n, filterPID)
	if raw == nil || n == 0 {
		return nil
	}
	defer C.free(unsafe.Pointer(raw))
	slice := unsafe.Slice(raw, int(n))
	out := make([]winEntry, 0, int(n))
	for i := 0; i < int(n); i++ {
		e := slice[i]
		out = append(out, winEntry{
			pid:       int32(e.pid),
			axRef:     unsafe.Pointer(e.axRef),
			windowID:  uint32(e.windowID),
			title:     C.GoString(e.title),
			appName:   C.GoString(e.appName),
			minimized: e.minimized != 0,
			onScreen:  e.onScreen != 0,
			zOrder:    int(e.zOrder),
		})
		C.free(unsafe.Pointer(e.title))
		C.free(unsafe.Pointer(e.appName))
	}
	sort.SliceStable(out, func(i, j int) bool {
		return out[i].zOrder < out[j].zOrder
	})
	return out
}

func showPanel() {
	n := len(list)
	if n == 0 {
		return
	}
	data := C.gf_newPanelData(C.int(n))
	for i, w := range list {
		ct := C.CString(w.title)
		ca := C.CString(w.appName)
		C.gf_setPanelEntry(data, C.int(i), ct, ca, w.axRef, C.uint(w.windowID),
			boolC(w.minimized), C.int(w.pid))
		C.free(unsafe.Pointer(ct))
		C.free(unsafe.Pointer(ca))
	}
	C.gf_showPanel(data, C.int(selected))
}

func boolC(b bool) C.int {
	if b {
		return 1
	}
	return 0
}
