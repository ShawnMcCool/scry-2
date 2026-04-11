//go:build linux

package main

import (
	"path/filepath"
	"testing"
)

func TestOpenBrowserLinux(t *testing.T) {
	cmd := browserCmdFn("http://localhost:4002")
	if len(cmd.Args) < 2 {
		t.Fatalf("expected at least 2 args, got %v", cmd.Args)
	}
	if filepath.Base(cmd.Args[0]) != "xdg-open" {
		t.Fatalf("expected xdg-open, got %q", filepath.Base(cmd.Args[0]))
	}
	if cmd.Args[1] != "http://localhost:4002" {
		t.Fatalf("expected URL as second arg, got %q", cmd.Args[1])
	}
}
