//go:build linux

package main

import "os/exec"

// browserCmdFn is a variable so tests can capture the command without executing it.
var browserCmdFn = func(url string) *exec.Cmd {
	return exec.Command("xdg-open", url)
}

func openBrowser(url string) {
	browserCmdFn(url).Start() //nolint:errcheck
}
