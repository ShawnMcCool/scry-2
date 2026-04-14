package main

import "os/exec"

// sendNotification sends a desktop notification via notify-send.
// Silently no-ops if notify-send is not installed.
func sendNotification(title, body string) {
	exec.Command("notify-send", "--app-name=Scry2", title, body).Start() //nolint:errcheck
}
