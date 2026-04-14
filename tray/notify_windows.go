package main

import "os/exec"

// sendNotification sends a Windows toast notification via PowerShell.
// Uses the BurntToast module if available; silently no-ops if unavailable.
func sendNotification(title, body string) {
	// PowerShell snippet: display a balloon tip via the Shell.Application COM object.
	// This works without any extra modules on all modern Windows versions.
	script := `
$notify = [System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')
$icon = [System.Windows.Forms.ToolTipIcon]::Info
$tip = New-Object System.Windows.Forms.NotifyIcon
$tip.Icon = [System.Drawing.SystemIcons]::Information
$tip.Visible = $true
$tip.ShowBalloonTip(5000, '` + title + `', '` + body + `', $icon)
Start-Sleep -Milliseconds 5500
$tip.Dispose()
`
	exec.Command("powershell", "-NoProfile", "-NonInteractive", "-Command", script).Start() //nolint:errcheck
}
