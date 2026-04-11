//go:build darwin

package main

import (
	"path/filepath"
	"testing"
)

func TestOpenBrowserDarwin(t *testing.T) {
	cmd := browserCmdFn("http://localhost:6015")
	if len(cmd.Args) < 2 {
		t.Fatalf("expected at least 2 args, got %v", cmd.Args)
	}
	if filepath.Base(cmd.Args[0]) != "open" {
		t.Fatalf("expected open, got %q", filepath.Base(cmd.Args[0]))
	}
	if cmd.Args[1] != "http://localhost:6015" {
		t.Fatalf("expected URL as second arg, got %q", cmd.Args[1])
	}
}
