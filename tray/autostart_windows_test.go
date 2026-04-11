//go:build windows

package main

import (
	"fmt"
	"testing"
	"time"

	"golang.org/x/sys/windows/registry"
)

func TestAutoStartWindows(t *testing.T) {
	// Use a throwaway registry key isolated to this test run.
	testKeyPath := fmt.Sprintf(`Software\scry2-test-%d`, time.Now().UnixNano())
	testValueName := "Scry2Test"

	// Ensure the test key exists so SET_VALUE succeeds.
	k, _, err := registry.CreateKey(registry.CURRENT_USER, testKeyPath, registry.ALL_ACCESS)
	if err != nil {
		t.Fatalf("failed to create test registry key: %v", err)
	}
	k.Close()

	t.Cleanup(func() {
		registry.DeleteKey(registry.CURRENT_USER, testKeyPath) //nolint:errcheck
	})

	origKeyPath := autoStartKeyPath
	origValueName := autoStartValueName
	autoStartKeyPath = testKeyPath
	autoStartValueName = testValueName
	defer func() {
		autoStartKeyPath = origKeyPath
		autoStartValueName = origValueName
	}()

	if IsAutoStartEnabled() {
		t.Fatal("expected disabled before any setup")
	}

	if err := SetAutoStart(true); err != nil {
		t.Fatalf("SetAutoStart(true): %v", err)
	}

	if !IsAutoStartEnabled() {
		t.Fatal("expected enabled after SetAutoStart(true)")
	}

	if err := SetAutoStart(false); err != nil {
		t.Fatalf("SetAutoStart(false): %v", err)
	}

	if IsAutoStartEnabled() {
		t.Fatal("expected disabled after SetAutoStart(false)")
	}
}
