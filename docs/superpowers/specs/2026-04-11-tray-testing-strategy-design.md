# System Tray Regression Testing Strategy

**Date:** 2026-04-11  
**Status:** Approved

## Context

The `tray/` directory contains a Go binary that manages the Scry2 system tray on Linux, macOS, and Windows. It handles backend subprocess lifecycle, a watchdog restart loop, platform-specific autostart persistence, and browser opening. Currently only one test exists (Linux autostart in `autostart_linux_test.go`). The goal is a testing infrastructure that catches regressions across all three platforms without manual installation on real machines.

## Chosen Approach: CI Matrix + Fake Backend Binary

GitHub Actions runs `go test ./...` on Linux, macOS, and Windows runners on every push. A fake backend binary enables realistic subprocess + watchdog testing without needing a real Elixir release.

---

## Phase 1: Interface Extraction

Refactor `tray/` to extract three interfaces, enabling dependency injection in tests.

### Interfaces

```go
// AutoStarter — platform-specific login persistence
type AutoStarter interface {
    IsEnabled() bool
    SetEnabled(bool) error
}

// BrowserOpener — platform-specific URL launcher
type BrowserOpener interface {
    Open(url string) error
}

// BackendRunner — subprocess lifecycle + watchdog
type BackendRunner interface {
    Start() error
    Stop() error
    IsRunning() bool
}
```

### Files to Modify

| File | Change |
|------|--------|
| `tray/backend.go` | Extract `RealBackend` struct implementing `BackendRunner`; add injectable `WatchdogInterval time.Duration` field (default `10s`); watchdog goroutine uses the field |
| `tray/autostart_linux.go` | Wrap existing functions into `LinuxAutoStarter` struct |
| `tray/autostart_darwin.go` | Wrap into `DarwinAutoStarter` struct |
| `tray/autostart_windows.go` | Wrap into `WindowsAutoStarter` struct |
| `tray/browser_linux.go` | Wrap into struct with injectable `cmdRunner func(string, ...string) *exec.Cmd` field |
| `tray/browser_darwin.go` | Same pattern |
| `tray/browser_windows.go` | Same pattern |
| `tray/main.go` | Wire concrete implementations at startup |

---

## Phase 2: Fake Backend Binary

Create `tray/testutil/fakebackend/main.go` — a tiny Go program that mimics the `bin/scry_2` command interface:

| Subcommand | Behavior |
|-----------|---------|
| `start` | Writes PID file (`$FAKE_BACKEND_PIDFILE`), exits 0 |
| `pid` | Exits 0 if PID file exists, exits 1 if not |
| `stop` | Removes PID file, exits 0 |

**Crash simulation:** `FAKE_BACKEND_CRASH_AFTER=N` causes the fake backend to delete its own PID file after N seconds, simulating a crash for watchdog tests.

`tray/backend_test.go` uses `TestMain` to compile `fakebackend` into a temp dir before any tests run:

```go
var fakeBackendBin string

func TestMain(m *testing.M) {
    dir, _ := os.MkdirTemp("", "fakebackend")
    fakeBackendBin = filepath.Join(dir, "fakebackend")
    cmd := exec.Command("go", "build", "-o", fakeBackendBin, "./testutil/fakebackend")
    if err := cmd.Run(); err != nil {
        log.Fatalf("failed to build fakebackend: %v", err)
    }
    os.Exit(m.Run())
}
```

---

## Phase 3: Tests

### Autostart Tests

**Linux** (`tray/autostart_linux_test.go`) — already exists, no changes needed. Pattern: `desktopPathFn` override + `t.TempDir()`.

**Darwin** (`tray/autostart_darwin_test.go`, `//go:build darwin`):
- Override plist path function via dependency injection (same pattern as Linux)
- Verify: disabled initially → enabled after `SetEnabled(true)` → disabled after `SetEnabled(false)`
- Assert plist file content is non-empty when enabled

**Windows** (`tray/autostart_windows_test.go`, `//go:build windows`):
- Write to throwaway registry key `HKCU\Software\scry2-test-<random>`
- `t.Cleanup` deletes the test key
- Same enable/disable/re-disable assertion pattern

### Backend Lifecycle Tests (`tray/backend_test.go`)

Uses fake backend binary compiled in `TestMain`. `WatchdogInterval` set to `100ms` for fast tests.

- `TestStart` — Start fake backend, assert `IsRunning() == true`
- `TestStop` — Start then Stop, assert `IsRunning() == false`
- `TestWatchdogRestarts` — Start with `FAKE_BACKEND_CRASH_AFTER=1` and `WatchdogInterval=100ms`, wait 2s, assert `IsRunning() == true` again

### Browser Opener Tests

One test per platform (`browser_linux_test.go`, `browser_darwin_test.go`, `browser_windows_test.go`). Each platform struct has an injectable `cmdRunner` function field. Tests inject a recorder that captures args without executing. Assert correct command and URL for platform (`xdg-open`, `open`, `cmd /c start`).

---

## Phase 4: GitHub Actions CI

Create `.github/workflows/tray-ci.yml`:

```yaml
name: Tray CI
on: [push, pull_request]
jobs:
  test:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest, windows-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version-file: tray/go.mod
      - run: go test ./...
        working-directory: tray
```

---

## Verification

1. `cd tray && go test ./...` passes locally on Linux
2. Push to GitHub — Actions matrix shows green on all three OS runners
3. Break the Linux autostart path — CI catches it
4. Break the watchdog restart logic — `TestWatchdogRestarts` fails

---

## What This Doesn't Cover (Intentional)

- **Tray UI** (icon, menu rendering, click handlers) — "compiles and handlers are wired" is sufficient; visual testing adds complexity without proportionate value
- **Install scripts** (`scripts/install*`, `.bat` files) — deferred; worth adding VM-based smoke tests if install script regressions actually occur
