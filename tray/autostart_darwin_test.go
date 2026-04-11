//go:build darwin

package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestAutoStartDarwin(t *testing.T) {
	tmp := t.TempDir()
	origPlistPathFn := plistPathFn
	plistPathFn = func() string {
		return filepath.Join(tmp, "LaunchAgents", "com.scry2.plist")
	}
	defer func() { plistPathFn = origPlistPathFn }()

	if IsAutoStartEnabled() {
		t.Fatal("expected disabled before any setup")
	}

	if err := SetAutoStart(true); err != nil {
		t.Fatalf("SetAutoStart(true): %v", err)
	}

	if !IsAutoStartEnabled() {
		t.Fatal("expected enabled after SetAutoStart(true)")
	}

	content, _ := os.ReadFile(plistPathFn())
	if len(content) == 0 {
		t.Fatal("plist file is empty")
	}

	if err := SetAutoStart(false); err != nil {
		t.Fatalf("SetAutoStart(false): %v", err)
	}

	if IsAutoStartEnabled() {
		t.Fatal("expected disabled after SetAutoStart(false)")
	}
}
