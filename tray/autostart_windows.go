//go:build windows

package main

import (
	"os"

	"golang.org/x/sys/windows/registry"
)

// autoStartKeyPath and autoStartValueName are variables so tests can override them.
var (
	autoStartKeyPath  = `Software\Microsoft\Windows\CurrentVersion\Run`
	autoStartValueName = "Scry2"
)

func IsAutoStartEnabled() bool {
	k, err := registry.OpenKey(registry.CURRENT_USER, autoStartKeyPath, registry.QUERY_VALUE)
	if err != nil {
		return false
	}
	defer k.Close()
	_, _, err = k.GetStringValue(autoStartValueName)
	return err == nil
}

func SetAutoStart(enabled bool) error {
	k, err := registry.OpenKey(registry.CURRENT_USER, autoStartKeyPath, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer k.Close()
	if !enabled {
		k.DeleteValue(autoStartValueName) //nolint:errcheck — OK if already absent
		return nil
	}
	exe, _ := os.Executable()
	return k.SetStringValue(autoStartValueName, `"`+exe+`"`)
}
