package updater_test

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"scry2/tray/updater"
)

func TestRealInstaller_Run(t *testing.T) {
	dir := t.TempDir()

	var script string
	var scriptName string
	if runtime.GOOS == "windows" {
		scriptName = "install.bat"
		script = "@echo off\necho ran > " + filepath.Join(dir, "sentinel.txt")
	} else {
		scriptName = "install"
		script = "#!/bin/sh\ntouch " + filepath.Join(dir, "sentinel.txt")
	}
	scriptPath := filepath.Join(dir, scriptName)
	if err := os.WriteFile(scriptPath, []byte(script), 0755); err != nil {
		t.Fatal(err)
	}

	installer := updater.NewRealInstaller()
	if err := installer.Run(dir); err != nil {
		t.Fatalf("Run: %v", err)
	}

	// The installer detaches the process — just verify Run returns nil (no error).
	// The install script runs independently after the tray exits.
}
