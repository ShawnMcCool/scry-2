package updater

import (
	"fmt"
	"os"
	"time"
)

// CurrentVersion is stamped at build time via -ldflags.
// It defaults to "dev" when not set, which disables update checks.
var CurrentVersion = "dev"

// MenuItem is the interface the orchestrator uses to control the tray menu item.
// The real systray item satisfies this via a thin adapter in main.go.
type MenuItem interface {
	SetTitle(title string)
	Disable()
	Enable()
	ClickedCh() <-chan struct{}
}

// Updater orchestrates version checks, downloads, and installs.
type Updater struct {
	currentVersion string
	checker        ReleaseChecker
	downloader     Downloader
	extractor      Extractor
	installer      Installer
	item           MenuItem
	exitFn         func(int) // injectable for tests; defaults to os.Exit

	pendingRelease *Release
	stopCh         chan struct{}
}

// New constructs an Updater with os.Exit as the exit function.
func New(currentVersion string, checker ReleaseChecker, downloader Downloader, extractor Extractor, installer Installer, item MenuItem) *Updater {
	return newWithExit(currentVersion, checker, downloader, extractor, installer, item, os.Exit)
}

func newWithExit(currentVersion string, checker ReleaseChecker, downloader Downloader, extractor Extractor, installer Installer, item MenuItem, exitFn func(int)) *Updater {
	return &Updater{
		currentVersion: currentVersion,
		checker:        checker,
		downloader:     downloader,
		extractor:      extractor,
		installer:      installer,
		item:           item,
		exitFn:         exitFn,
		stopCh:         make(chan struct{}),
	}
}

// CheckOnce performs a single update check and updates the menu item title.
func (u *Updater) CheckOnce() {
	if u.currentVersion == "dev" {
		return
	}
	archiveName, err := CurrentArchiveName(u.currentVersion)
	if err != nil {
		return // unsupported platform — skip silently
	}
	release, err := u.checker.LatestRelease(archiveName)
	if err != nil || !IsNewer(release.Version, u.currentVersion) {
		u.pendingRelease = nil
		u.item.SetTitle("Check for Updates")
		return
	}
	u.pendingRelease = &release
	u.item.SetTitle(fmt.Sprintf("Update Now (%s)", release.Version))
}

// ApplyUpdate downloads and installs the pending release, then exits.
func (u *Updater) ApplyUpdate() {
	if u.pendingRelease == nil {
		return
	}
	release := *u.pendingRelease
	u.item.Disable()
	u.item.SetTitle(fmt.Sprintf("Updating to %s…", release.Version))

	archivePath, err := u.downloader.Fetch(release.ArchiveURL)
	if err != nil {
		u.resetAfterFailure(release.Version)
		return
	}
	defer os.Remove(archivePath)

	destDir, err := os.MkdirTemp("", "scry2-update-*")
	if err != nil {
		u.resetAfterFailure(release.Version)
		return
	}
	defer os.RemoveAll(destDir)

	if err := u.extractor.Extract(archivePath, destDir); err != nil {
		u.resetAfterFailure(release.Version)
		return
	}

	if err := u.installer.Run(destDir); err != nil {
		u.resetAfterFailure(release.Version)
		return
	}

	u.exitFn(0)
}

func (u *Updater) resetAfterFailure(version string) {
	u.item.SetTitle("Update failed — try again")
	u.item.Enable()
	time.AfterFunc(5*time.Second, func() {
		u.item.SetTitle(fmt.Sprintf("Update Now (%s)", version))
	})
}

// StartWithInterval checks immediately then rechecks on the given interval.
// Call Stop() to halt the background goroutine.
func (u *Updater) StartWithInterval(interval time.Duration) {
	go func() {
		u.CheckOnce()
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				u.CheckOnce()
			case <-u.stopCh:
				return
			}
		}
	}()
}

// Start checks immediately then rechecks hourly.
func (u *Updater) Start() {
	u.StartWithInterval(time.Hour)
}

// Stop halts the background goroutine.
func (u *Updater) Stop() {
	close(u.stopCh)
}
