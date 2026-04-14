package main

import "os/exec"

// sendNotification sends a macOS notification via osascript.
func sendNotification(title, body string) {
	script := `display notification "` + body + `" with title "` + title + `"`
	exec.Command("osascript", "-e", script).Start() //nolint:errcheck
}
