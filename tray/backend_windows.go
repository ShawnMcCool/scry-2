//go:build windows

package main

import (
	"os/exec"
	"syscall"
)

// setCmdAttrs hides the console window that Windows would otherwise open when
// the tray (a windowsgui binary) spawns a console subprocess like scry_2.bat.
// CREATE_NO_WINDOW prevents cmd.exe from creating a visible console, and child
// processes it spawns (elixir.bat, erl.exe) inherit the console-less session.
func setCmdAttrs(c *exec.Cmd) {
	c.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
}
