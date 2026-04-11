//go:build windows

package main

import (
	"os"
	"path/filepath"
)

// dataDirFn is a variable so tests can override the path.
var dataDirFn = func() string {
	if appdata := os.Getenv("APPDATA"); appdata != "" {
		return filepath.Join(appdata, "scry_2")
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "scry_2")
}

// DataDir mirrors Scry2.Platform.data_dir/0 for the tray binary.
// Must stay in sync with lib/scry_2/platform.ex.
func DataDir() string {
	return dataDirFn()
}
