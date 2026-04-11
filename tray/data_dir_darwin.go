//go:build darwin

package main

import (
	"os"
	"path/filepath"
)

// dataDirFn is a variable so tests can override the path.
var dataDirFn = func() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "Application Support", "scry_2")
}

// DataDir mirrors Scry2.Platform.data_dir/0 for the tray binary.
// Must stay in sync with lib/scry_2/platform.ex.
func DataDir() string {
	return dataDirFn()
}
