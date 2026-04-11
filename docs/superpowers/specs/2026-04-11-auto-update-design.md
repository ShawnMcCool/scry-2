# Auto-Update Design

**Date:** 2026-04-11  
**Status:** Approved

## Context

Scry2 is distributed as a self-contained archive (Elixir release + Go tray binary) published to GitHub Releases. Currently players must manually download, extract, and run the install script to upgrade. This design adds automatic update detection and one-click installation so players never need to touch GitHub.

Migrations already run automatically via `Ecto.Migrator` in the supervision tree on every startup — no migration work is needed.

## Decision

All update logic lives in the tray binary (`scry2-tray`). The tray already owns the backend lifecycle (start/stop/pid). Updates are a lifecycle event. This keeps the feature self-contained, works even when the backend is unhealthy, and requires zero new Elixir code or IPC between the two processes.

Zero new Go dependencies — everything uses the standard library (`net/http`, `encoding/json`, `archive/tar`, `compress/gzip`, `archive/zip`, `os/exec`, `runtime`).

## Module Structure

All update logic lives in `tray/updater/`:

```
tray/
  updater/
    version.go      — semver parsing and comparison (pure functions)
    platform.go     — runtime.GOOS/GOARCH → archive suffix and extension
    github.go       — GitHub Releases API client (ReleaseChecker interface + real impl)
    downloader.go   — HTTP archive download to temp file (Downloader interface + real impl)
    extractor.go    — tar.gz (Linux/macOS) and zip (Windows) extraction (Extractor interface + real impl)
    installer.go    — exec install script detached from tray process (Installer interface + real impl)
    updater.go      — orchestrator: owns menu state, runs ticker, coordinates flow
    *_test.go       — per-file unit tests; mock implementations live alongside tests
```

## Core Interfaces

```go
type ReleaseChecker interface {
    LatestRelease(platform string) (Release, error)
}

type Downloader interface {
    Fetch(url string) (path string, err error) // returns path to temp file
}

type Extractor interface {
    Extract(archivePath, destDir string) error
}

type Installer interface {
    Run(extractedDir string) error
}

type MenuItem interface {
    SetTitle(title string)
    Disable()
    Enable()
    ClickedCh() <-chan struct{}
}
```

The `Updater` struct is constructed with these interfaces, making it fully testable without touching the real systray, network, or filesystem.

## Version Embedding

The current version is stamped at build time via `-ldflags`:

```
go build -ldflags="-X 'scry2/tray/updater.CurrentVersion=0.2.0'" -o scry2-tray .
```

This one-line addition goes into both `scripts/release` and `.github/workflows/release.yml` (which already extracts the version from the git tag).

When `version == "dev"` (no `-ldflags` passed), the updater skips all checks silently.

## Data Flow

### Check flow (on startup and hourly tick)

1. `checker.LatestRelease(platform)` → `Release{Version, ArchiveURL}`
2. `version.IsNewer(latest, current)` → bool
3. If newer: set menu title to `"Update Now (v0.3.0)"`; store `Release` for use on click
4. If same or error: set menu title to `"Check for Updates"` (errors are silent — no noise for background checks)
5. Hourly `time.Ticker` repeats steps 1–4

### Update flow (on "Update Now" click)

1. Disable menu item; set title to `"Updating to v0.3.0…"`
2. `downloader.Fetch(archiveURL)` → temp file path
3. `extractor.Extract(tempFile, tempDir)` → extracted directory tree
4. `installer.Run(tempDir)` → execs `./install` (or `install.bat`) detached from the tray process group (new session/process group so the install script can kill the tray)
5. `os.Exit(0)` — the install script stops the old tray, copies new files (including new tray binary), and starts the new tray

### Failure handling

On any error in steps 2–4: re-enable menu item, set title to `"Update failed — try again"`, revert to `"Update Now (v0.3.0)"` after 5 seconds. No panic, no crash.

## Platform Detection

`platform.go` maps `runtime.GOOS + "/" + runtime.GOARCH` to the archive name used in GitHub Releases:

| GOOS/GOARCH     | Archive suffix             |
|-----------------|----------------------------|
| linux/amd64     | linux-x86_64.tar.gz        |
| darwin/arm64    | macos-aarch64.tar.gz       |
| darwin/amd64    | macos-x86_64.tar.gz        |
| windows/amd64   | windows-x86_64.zip         |

Unknown combinations return an error; update checks are skipped silently.

## GitHub API

Calls `https://api.github.com/repos/shawnmccool/scry_2/releases/latest` (public repo, no auth). Parses `tag_name` for the version and scans `assets` for the matching platform archive URL. One request per check.

## Install Script Detachment

On Unix:
```go
cmd := exec.Command(filepath.Join(extractedDir, "install"))
cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
cmd.Start() // not Wait — we exit immediately after
```

On Windows:
```go
cmd := exec.Command(filepath.Join(extractedDir, "install.bat"))
cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP}
cmd.Start()
```

After `cmd.Start()`, the tray calls `os.Exit(0)`. The install script runs independently, kills the old tray (already exited), copies new files, and launches the new tray.

Because `syscall.SysProcAttr` has different fields on Unix vs Windows, the real `Installer` implementation is split into build-tagged files: `installer_unix.go` (Linux + macOS) and `installer_windows.go`.

## Testing Strategy

Each file has a corresponding `_test.go`. All tests use stdlib only (`net/http/httptest` for fake HTTP servers, `archive/tar`+`compress/gzip`+`archive/zip` for in-memory fixture archives).

| File | What is tested |
|------|----------------|
| `version_test.go` | Comparison: newer/same/older; malformed tags → false, no panic |
| `platform_test.go` | All known GOOS/GOARCH pairs; unknown → error |
| `github_test.go` | Happy path JSON parse; no matching asset → error; non-200 → error |
| `downloader_test.go` | Downloaded bytes match source; HTTP error → error |
| `extractor_test.go` | tar.gz and zip: file content and permissions preserved; install script present and executable |
| `updater_test.go` | Update available → menu shows "Update Now"; no update → "Check for Updates"; checker error → silent; click triggers download→extract→install in order; download failure → menu resets; hourly ticker triggers re-check |

The `MenuItem` interface is mocked in tests so the orchestrator never touches the real systray.

## Build Script Changes

`scripts/release` and `.github/workflows/release.yml` both gain the `-ldflags` version stamp on the `go build` line. The CI workflow already extracts the version from the git tag into a shell variable; it just needs to pass it through.

## Acceptance Criteria

- On tray startup with `version != "dev"`, GitHub API is called within a few seconds
- If a newer release exists, menu item reads `"Update Now (vX.Y.Z)"`
- If no update, menu item reads `"Check for Updates"`
- Clicking "Check for Updates" triggers an immediate re-check
- Clicking "Update Now" shows `"Updating to vX.Y.Z…"`, downloads, extracts, and runs install detached
- After install script runs, a new tray appears with the new version
- All failure paths reset the menu gracefully without crashing the tray
- `go test ./updater/...` passes on Linux, macOS, and Windows
