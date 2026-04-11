//go:build linux

package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestAutoStartLinux(t *testing.T) {
	// Override desktopPath to use a temp dir
	tmp := t.TempDir()
	origDesktopPath := desktopPathFn
	desktopPathFn = func() string {
		return filepath.Join(tmp, "autostart", "scry2.desktop")
	}
	defer func() { desktopPathFn = origDesktopPath }()

	if IsAutoStartEnabled() {
		t.Fatal("expected disabled before any setup")
	}

	if err := SetAutoStart(true); err != nil {
		t.Fatalf("SetAutoStart(true): %v", err)
	}

	if !IsAutoStartEnabled() {
		t.Fatal("expected enabled after SetAutoStart(true)")
	}

	content, _ := os.ReadFile(desktopPathFn())
	if len(content) == 0 {
		t.Fatal("desktop file is empty")
	}

	if err := SetAutoStart(false); err != nil {
		t.Fatalf("SetAutoStart(false): %v", err)
	}

	if IsAutoStartEnabled() {
		t.Fatal("expected disabled after SetAutoStart(false)")
	}
}
