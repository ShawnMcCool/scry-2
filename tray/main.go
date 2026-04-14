package main

import (
	_ "embed"
	"time"

	"github.com/getlantern/systray"
	"scry2/tray/updater"
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
	mNotResponding := systray.AddMenuItem("⚠ Backend not responding — click for help", "Open the operations page")
	mNotResponding.Hide()
	systray.AddSeparator()
	mUpdate := systray.AddMenuItem("Check for Updates", "Check for a newer version of Scry2")
	systray.AddSeparator()
	mQuit := systray.AddMenuItem("Quit", "Stop Scry2 and quit")

	firstRun := IsFirstRun()

	backend.OnNotResponding = func() {
		mNotResponding.Show()
		systray.SetTooltip("Scry2 — backend not responding")
		go sendNotification("Scry2 is not responding", "The backend failed to start. Click the tray icon for help.")
	}
	backend.OnRecovered = func() {
		mNotResponding.Hide()
		systray.SetTooltip("Scry2 — MTGA Stats")
	}

	backend.Start()
	backend.StartWatchdog(quitCh)

	if firstRun {
		go func() {
			if waitForBackendReady(30 * time.Second) {
				openBrowser(DashboardURL)
			}
		}()
	}

	u := updater.New(
		updater.CurrentVersion,
		updater.NewGitHubChecker("https://api.github.com/repos/shawnmccool/scry_2/releases/latest"),
		updater.NewHTTPDownloader(),
		updater.NewArchiveExtractor(),
		updater.NewRealInstaller(),
		&systrayMenuItem{mUpdate},
	)
	u.Start()

	go func() {
		for {
			select {
			case <-mOpen.ClickedCh:
				openBrowser(DashboardURL)
			case <-mNotResponding.ClickedCh:
				openBrowser(DashboardURL + "/operations")
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
			case <-mUpdate.ClickedCh:
				u.ApplyUpdate()
			case <-mQuit.ClickedCh:
				u.Stop()
				close(quitCh)
				backend.Stop()
				systray.Quit()
				return
			}
		}
	}()
}

func onExit() {}
