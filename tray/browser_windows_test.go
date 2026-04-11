//go:build windows

package main

import (
	"path/filepath"
	"testing"
)

func TestOpenBrowserWindows(t *testing.T) {
	cmd := browserCmdFn("http://localhost:4002")
	// Expected: cmd /c start <url>
	if len(cmd.Args) < 4 {
		t.Fatalf("expected at least 4 args, got %v", cmd.Args)
	}
	if filepath.Base(cmd.Args[0]) != "cmd" && filepath.Base(cmd.Args[0]) != "cmd.exe" {
		t.Fatalf("expected cmd, got %q", filepath.Base(cmd.Args[0]))
	}
	if cmd.Args[1] != "/c" || cmd.Args[2] != "start" {
		t.Fatalf("expected /c start, got %v", cmd.Args[1:3])
	}
	if cmd.Args[3] != "http://localhost:4002" {
		t.Fatalf("expected URL as fourth arg, got %q", cmd.Args[3])
	}
}
