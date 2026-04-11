package main

import (
	_ "embed"

	"github.com/getlantern/systray"
)

//go:embed assets/icon.png
var icon []byte

var (
	backend = newRealBackend()
	quitCh  = make(chan struct{})
)

func main() {
	systray.Run(onReady, onExit)
}

func onReady() {
	systray.SetIcon(icon)
	systray.SetTooltip("Scry2 — MTGA Stats")

	mOpen := systray.AddMenuItem("Open", "Open Scry2 in browser")
	mAutoStart := systray.AddMenuItemCheckbox("Auto-start on login", "Toggle auto-start on login", IsAutoStartEnabled())
	systray.AddSeparator()
	mQuit := systray.AddMenuItem("Quit", "Stop Scry2 and quit")

	backend.Start()
	backend.StartWatchdog(quitCh)

	go func() {
		for {
			select {
			case <-mOpen.ClickedCh:
				openBrowser("http://localhost:4002")
			case <-mAutoStart.ClickedCh:
				if mAutoStart.Checked() {
					if err := SetAutoStart(false); err == nil {
						mAutoStart.Uncheck()
					}
				} else {
					if err := SetAutoStart(true); err == nil {
						mAutoStart.Check()
					}
				}
			case <-mQuit.ClickedCh:
				close(quitCh)
				backend.Stop()
				systray.Quit()
				return
			}
		}
	}()
}

func onExit() {}
