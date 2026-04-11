//go:build linux

package main

import (
	"fmt"
	"os"
	"path/filepath"
)

// desktopPathFn is a variable so tests can override it.
var desktopPathFn = func() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "autostart", "scry2.desktop")
}

func IsAutoStartEnabled() bool {
	_, err := os.Stat(desktopPathFn())
	return err == nil
}

func SetAutoStart(enabled bool) error {
	path := desktopPathFn()
	if !enabled {
		err := os.Remove(path)
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	exe, _ := os.Executable()
	content := fmt.Sprintf(`[Desktop Entry]
Type=Application
Name=Scry2
Exec=%s
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
`, exe)
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(content), 0644)
}
