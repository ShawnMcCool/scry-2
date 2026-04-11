package updater_test

import (
	"errors"
	"sync"
	"testing"
	"time"

	"scry2/tray/updater"
)

// --- Mocks ---

type mockChecker struct {
	mu      sync.Mutex
	calls   int
	release updater.Release
	err     error
}

func (m *mockChecker) LatestRelease(_ string) (updater.Release, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.calls++
	return m.release, m.err
}

type mockDownloader struct {
	path string
	err  error
}

func (m *mockDownloader) Fetch(_ string) (string, error) { return m.path, m.err }

type mockExtractor struct {
	err error
}

func (m *mockExtractor) Extract(_, _ string) error { return m.err }

type mockInstaller struct {
	called bool
	err    error
}

func (m *mockInstaller) Run(_ string) error {
	m.called = true
	return m.err
}

type mockMenuItem struct {
	mu      sync.Mutex
	title   string
	enabled bool
	clicked chan struct{}
}

func newMockMenuItem() *mockMenuItem {
	return &mockMenuItem{enabled: true, clicked: make(chan struct{}, 1)}
}

func (m *mockMenuItem) SetTitle(title string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.title = title
}
func (m *mockMenuItem) Disable() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.enabled = false
}
func (m *mockMenuItem) Enable() {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.enabled = true
}
func (m *mockMenuItem) ClickedCh() <-chan struct{} { return m.clicked }
func (m *mockMenuItem) Title() string {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.title
}

// --- Tests ---

func TestUpdater_UpdateAvailable(t *testing.T) {
	checker := &mockChecker{release: updater.Release{Version: "v0.3.0", ArchiveURL: "http://example.com/archive.tar.gz"}}
	item := newMockMenuItem()

	u := updater.New("v0.2.0", checker, &mockDownloader{}, &mockExtractor{}, &mockInstaller{}, item)
	u.CheckOnce()

	if item.Title() != "Update Now (v0.3.0)" {
		t.Errorf("title = %q, want %q", item.Title(), "Update Now (v0.3.0)")
	}
}

func TestUpdater_NoUpdate(t *testing.T) {
	checker := &mockChecker{release: updater.Release{Version: "v0.2.0", ArchiveURL: "http://example.com/archive.tar.gz"}}
	item := newMockMenuItem()

	u := updater.New("v0.2.0", checker, &mockDownloader{}, &mockExtractor{}, &mockInstaller{}, item)
	u.CheckOnce()

	if item.Title() != "Check for Updates" {
		t.Errorf("title = %q, want %q", item.Title(), "Check for Updates")
	}
}

func TestUpdater_CheckerError_Silent(t *testing.T) {
	checker := &mockChecker{err: errors.New("network error")}
	item := newMockMenuItem()

	u := updater.New("v0.2.0", checker, &mockDownloader{}, &mockExtractor{}, &mockInstaller{}, item)
	u.CheckOnce()

	if item.Title() != "Check for Updates" {
		t.Errorf("on checker error title should be %q, got %q", "Check for Updates", item.Title())
	}
}

func TestUpdater_DownloadFailure_ResetsMenu(t *testing.T) {
	checker := &mockChecker{release: updater.Release{Version: "v0.3.0", ArchiveURL: "http://example.com/archive.tar.gz"}}
	downloader := &mockDownloader{err: errors.New("download failed")}
	item := newMockMenuItem()

	u := updater.New("v0.2.0", checker, downloader, &mockExtractor{}, &mockInstaller{}, item)
	u.CheckOnce()
	u.ApplyUpdate()

	// After failure, menu should NOT be stuck at "Updating..."
	// It should show "Update failed — try again" immediately, then revert after 5s.
	title := item.Title()
	if title != "Update failed — try again" {
		t.Errorf("after download failure title = %q, want %q", title, "Update failed — try again")
	}
}

func TestUpdater_ApplyUpdate_CallsInstaller(t *testing.T) {
	checker := &mockChecker{release: updater.Release{Version: "v0.3.0", ArchiveURL: "http://example.com/archive.tar.gz"}}
	installer := &mockInstaller{}
	item := newMockMenuItem()
	exited := false

	u := updater.NewForTest("v0.2.0", checker, &mockDownloader{path: "/tmp/fake.tar.gz"}, &mockExtractor{}, installer, item, func(int) { exited = true })
	u.CheckOnce()
	u.ApplyUpdate()

	if !installer.called {
		t.Error("expected installer.Run to have been called")
	}
	if !exited {
		t.Error("expected exit to have been called after successful install")
	}
}

func TestUpdater_DevVersion_SkipsCheck(t *testing.T) {
	checker := &mockChecker{}
	item := newMockMenuItem()

	u := updater.New("dev", checker, &mockDownloader{}, &mockExtractor{}, &mockInstaller{}, item)
	u.CheckOnce()

	if checker.calls != 0 {
		t.Errorf("expected no API calls for dev version, got %d", checker.calls)
	}
}

func TestUpdater_HourlyTicker(t *testing.T) {
	checker := &mockChecker{release: updater.Release{Version: "v0.2.0"}}
	item := newMockMenuItem()

	u := updater.New("v0.2.0", checker, &mockDownloader{}, &mockExtractor{}, &mockInstaller{}, item)
	u.StartWithInterval(50 * time.Millisecond)
	defer u.Stop()

	time.Sleep(180 * time.Millisecond)

	checker.mu.Lock()
	calls := checker.calls
	checker.mu.Unlock()

	if calls < 3 {
		t.Errorf("expected at least 3 checks in 180ms at 50ms interval, got %d", calls)
	}
}
