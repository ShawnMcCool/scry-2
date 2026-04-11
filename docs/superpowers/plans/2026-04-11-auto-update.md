# Auto-Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add automatic update detection and one-click installation to the `scry2-tray` binary, so players never need to manually download a new release.

**Architecture:** All update logic lives in a new `tray/updater/` package. The tray checks GitHub Releases API on startup and hourly. When a newer version is found the menu item changes to "Update Now (vX.Y.Z)". Clicking it downloads the archive, extracts to a temp dir, runs the install script detached from the tray process, and exits — the install script stops the old tray, copies new files, and starts the new one.

**Tech Stack:** Go stdlib only (`net/http`, `encoding/json`, `archive/tar`, `compress/gzip`, `archive/zip`, `os/exec`, `syscall`, `runtime`). Build-time version stamping via `-ldflags`.

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `tray/updater/version.go` | Create | Semver parsing and comparison |
| `tray/updater/version_test.go` | Create | Pure function tests |
| `tray/updater/platform.go` | Create | GOOS/GOARCH → archive suffix |
| `tray/updater/platform_test.go` | Create | Platform mapping tests |
| `tray/updater/github.go` | Create | GitHub Releases API client + `ReleaseChecker` interface |
| `tray/updater/github_test.go` | Create | `httptest` server tests |
| `tray/updater/downloader.go` | Create | HTTP archive download + `Downloader` interface |
| `tray/updater/downloader_test.go` | Create | `httptest` server tests |
| `tray/updater/extractor.go` | Create | tar.gz + zip extraction + `Extractor` interface |
| `tray/updater/extractor_test.go` | Create | In-memory archive fixture tests |
| `tray/updater/installer_unix.go` | Create | Detached exec on Linux/macOS (`//go:build !windows`) |
| `tray/updater/installer_windows.go` | Create | Detached exec on Windows (`//go:build windows`) |
| `tray/updater/installer_test.go` | Create | Mock-based installer tests |
| `tray/updater/updater.go` | Create | Orchestrator: menu state, ticker, flow coordination |
| `tray/updater/updater_test.go` | Create | Orchestrator tests with all interfaces mocked |
| `tray/main.go` | Modify | Wire up updater and new menu item |
| `scripts/release` | Modify | Add `-ldflags` version stamp to `go build` line |
| `.github/workflows/release.yml` | Modify | Add `-ldflags` version stamp to both tray build steps |

---

## Task 1: version.go — semver parsing and comparison

**Files:**
- Create: `tray/updater/version.go`
- Create: `tray/updater/version_test.go`

- [ ] **Step 1: Write failing tests**

Create `tray/updater/version_test.go`:

```go
package updater_test

import (
	"testing"

	"scry2/tray/updater"
)

func TestIsNewer(t *testing.T) {
	tests := []struct {
		latest  string
		current string
		want    bool
	}{
		{"v0.3.0", "v0.2.0", true},
		{"v0.2.1", "v0.2.0", true},
		{"v1.0.0", "v0.9.9", true},
		{"v0.2.0", "v0.2.0", false},
		{"v0.1.0", "v0.2.0", false},
		{"v0.2.0", "v0.2.1", false},
		{"bad-tag", "v0.2.0", false},
		{"v0.2.0", "bad-tag", false},
		{"", "v0.2.0", false},
		{"v0.2.0", "", false},
	}
	for _, tc := range tests {
		got := updater.IsNewer(tc.latest, tc.current)
		if got != tc.want {
			t.Errorf("IsNewer(%q, %q) = %v, want %v", tc.latest, tc.current, got, tc.want)
		}
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

```
cd tray && go test ./updater/... -run TestIsNewer -v
```

Expected: compilation error — package doesn't exist yet.

- [ ] **Step 3: Create version.go**

Create `tray/updater/version.go`:

```go
package updater

import (
	"fmt"
	"strings"
)

// IsNewer reports whether latest is a higher semver than current.
// Both must be in "vMAJOR.MINOR.PATCH" form; any parse error returns false.
func IsNewer(latest, current string) bool {
	lv, err := parseSemver(latest)
	if err != nil {
		return false
	}
	cv, err := parseSemver(current)
	if err != nil {
		return false
	}
	return lv[0] > cv[0] ||
		(lv[0] == cv[0] && lv[1] > cv[1]) ||
		(lv[0] == cv[0] && lv[1] == cv[1] && lv[2] > cv[2])
}

func parseSemver(v string) ([3]int, error) {
	v = strings.TrimPrefix(v, "v")
	var major, minor, patch int
	if _, err := fmt.Sscanf(v, "%d.%d.%d", &major, &minor, &patch); err != nil {
		return [3]int{}, fmt.Errorf("invalid semver %q: %w", v, err)
	}
	return [3]int{major, minor, patch}, nil
}
```

- [ ] **Step 4: Run tests**

```
cd tray && go test ./updater/... -run TestIsNewer -v
```

Expected: PASS — all 10 cases green.

- [ ] **Step 5: Commit**

```bash
jj desc -m "feat: add updater/version.go — semver comparison"
jj new
```

---

## Task 2: platform.go — archive name resolution

**Files:**
- Create: `tray/updater/platform.go`
- Create: `tray/updater/platform_test.go`

- [ ] **Step 1: Write failing tests**

Create `tray/updater/platform_test.go`:

```go
package updater_test

import (
	"testing"

	"scry2/tray/updater"
)

func TestArchiveName(t *testing.T) {
	tests := []struct {
		goos    string
		goarch  string
		version string
		want    string
		wantErr bool
	}{
		{"linux", "amd64", "v0.3.0", "scry_2-v0.3.0-linux-x86_64.tar.gz", false},
		{"darwin", "arm64", "v0.3.0", "scry_2-v0.3.0-macos-aarch64.tar.gz", false},
		{"darwin", "amd64", "v0.3.0", "scry_2-v0.3.0-macos-x86_64.tar.gz", false},
		{"windows", "amd64", "v0.3.0", "scry_2-v0.3.0-windows-x86_64.zip", false},
		{"freebsd", "amd64", "v0.3.0", "", true},
	}
	for _, tc := range tests {
		got, err := updater.ArchiveName(tc.goos, tc.goarch, tc.version)
		if (err != nil) != tc.wantErr {
			t.Errorf("ArchiveName(%q,%q,%q) err=%v, wantErr=%v", tc.goos, tc.goarch, tc.version, err, tc.wantErr)
			continue
		}
		if got != tc.want {
			t.Errorf("ArchiveName(%q,%q,%q) = %q, want %q", tc.goos, tc.goarch, tc.version, got, tc.want)
		}
	}
}

func TestCurrentArchiveName(t *testing.T) {
	// Just verify it doesn't panic and returns a non-empty string on known CI platforms.
	// (This test is skipped on unknown platforms by TestArchiveName's error path above.)
	name, err := updater.CurrentArchiveName("v0.3.0")
	if err != nil {
		t.Skipf("platform not supported: %v", err)
	}
	if name == "" {
		t.Error("expected non-empty archive name")
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

```
cd tray && go test ./updater/... -run TestArchiveName -v
```

Expected: compilation error.

- [ ] **Step 3: Create platform.go**

Create `tray/updater/platform.go`:

```go
package updater

import (
	"fmt"
	"runtime"
)

// ArchiveName returns the release archive filename for the given platform and version.
// goos and goarch should be runtime.GOOS and runtime.GOARCH values.
func ArchiveName(goos, goarch, version string) (string, error) {
	suffix, err := archiveSuffix(goos, goarch)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("scry_2-%s-%s", version, suffix), nil
}

// CurrentArchiveName returns the archive name for the current runtime platform.
func CurrentArchiveName(version string) (string, error) {
	return ArchiveName(runtime.GOOS, runtime.GOARCH, version)
}

func archiveSuffix(goos, goarch string) (string, error) {
	switch goos + "/" + goarch {
	case "linux/amd64":
		return "linux-x86_64.tar.gz", nil
	case "darwin/arm64":
		return "macos-aarch64.tar.gz", nil
	case "darwin/amd64":
		return "macos-x86_64.tar.gz", nil
	case "windows/amd64":
		return "windows-x86_64.zip", nil
	default:
		return "", fmt.Errorf("unsupported platform: %s/%s", goos, goarch)
	}
}
```

- [ ] **Step 4: Run tests**

```
cd tray && go test ./updater/... -run TestArchiveName -v
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj desc -m "feat: add updater/platform.go — archive name resolution"
jj new
```

---

## Task 3: github.go — GitHub Releases API client

**Files:**
- Create: `tray/updater/github.go`
- Create: `tray/updater/github_test.go`

- [ ] **Step 1: Write failing tests**

Create `tray/updater/github_test.go`:

```go
package updater_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"scry2/tray/updater"
)

func TestGitHubChecker_LatestRelease_HappyPath(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{
			"tag_name": "v0.3.0",
			"assets": []map[string]any{
				{"name": "scry_2-v0.3.0-linux-x86_64.tar.gz", "browser_download_url": "https://example.com/scry_2-v0.3.0-linux-x86_64.tar.gz"},
				{"name": "scry_2-v0.3.0-macos-aarch64.tar.gz", "browser_download_url": "https://example.com/scry_2-v0.3.0-macos-aarch64.tar.gz"},
			},
		})
	}))
	defer srv.Close()

	checker := updater.NewGitHubChecker(srv.URL)
	release, err := checker.LatestRelease("scry_2-v0.3.0-linux-x86_64.tar.gz")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if release.Version != "v0.3.0" {
		t.Errorf("Version = %q, want %q", release.Version, "v0.3.0")
	}
	if release.ArchiveURL != "https://example.com/scry_2-v0.3.0-linux-x86_64.tar.gz" {
		t.Errorf("ArchiveURL = %q", release.ArchiveURL)
	}
}

func TestGitHubChecker_LatestRelease_NoMatchingAsset(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]any{
			"tag_name": "v0.3.0",
			"assets":   []map[string]any{},
		})
	}))
	defer srv.Close()

	checker := updater.NewGitHubChecker(srv.URL)
	_, err := checker.LatestRelease("scry_2-v0.3.0-linux-x86_64.tar.gz")
	if err == nil {
		t.Fatal("expected error for missing asset, got nil")
	}
}

func TestGitHubChecker_LatestRelease_ServerError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()

	checker := updater.NewGitHubChecker(srv.URL)
	_, err := checker.LatestRelease("scry_2-v0.3.0-linux-x86_64.tar.gz")
	if err == nil {
		t.Fatal("expected error for 500 response, got nil")
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

```
cd tray && go test ./updater/... -run TestGitHubChecker -v
```

Expected: compilation error.

- [ ] **Step 3: Create github.go**

Create `tray/updater/github.go`:

```go
package updater

import (
	"encoding/json"
	"fmt"
	"net/http"
)

// Release holds the version and download URL for a specific platform's archive.
type Release struct {
	Version    string
	ArchiveURL string
}

// ReleaseChecker fetches the latest release for a given archive filename.
type ReleaseChecker interface {
	// LatestRelease returns the latest release whose asset matches archiveName.
	LatestRelease(archiveName string) (Release, error)
}

// GitHubChecker fetches release info from the GitHub Releases API.
type GitHubChecker struct {
	apiURL string // base URL; defaults to GitHub API, overridable in tests
}

// NewGitHubChecker creates a checker pointed at the given base URL.
// Pass the real GitHub API URL in production:
//
//	updater.NewGitHubChecker("https://api.github.com/repos/shawnmccool/scry_2/releases/latest")
func NewGitHubChecker(apiURL string) *GitHubChecker {
	return &GitHubChecker{apiURL: apiURL}
}

type githubRelease struct {
	TagName string         `json:"tag_name"`
	Assets  []githubAsset  `json:"assets"`
}

type githubAsset struct {
	Name               string `json:"name"`
	BrowserDownloadURL string `json:"browser_download_url"`
}

func (c *GitHubChecker) LatestRelease(archiveName string) (Release, error) {
	resp, err := http.Get(c.apiURL) //nolint:noctx
	if err != nil {
		return Release{}, fmt.Errorf("github releases request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return Release{}, fmt.Errorf("github releases returned %d", resp.StatusCode)
	}

	var gr githubRelease
	if err := json.NewDecoder(resp.Body).Decode(&gr); err != nil {
		return Release{}, fmt.Errorf("github releases decode: %w", err)
	}

	for _, asset := range gr.Assets {
		if asset.Name == archiveName {
			return Release{Version: gr.TagName, ArchiveURL: asset.BrowserDownloadURL}, nil
		}
	}

	return Release{}, fmt.Errorf("no asset %q in release %s", archiveName, gr.TagName)
}
```

- [ ] **Step 4: Run tests**

```
cd tray && go test ./updater/... -run TestGitHubChecker -v
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj desc -m "feat: add updater/github.go — GitHub Releases API client"
jj new
```

---

## Task 4: downloader.go — archive download

**Files:**
- Create: `tray/updater/downloader.go`
- Create: `tray/updater/downloader_test.go`

- [ ] **Step 1: Write failing tests**

Create `tray/updater/downloader_test.go`:

```go
package updater_test

import (
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"scry2/tray/updater"
)

func TestHTTPDownloader_Fetch_HappyPath(t *testing.T) {
	want := []byte("fake archive content")
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write(want)
	}))
	defer srv.Close()

	d := updater.NewHTTPDownloader()
	path, err := d.Fetch(srv.URL)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	defer os.Remove(path)

	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read temp file: %v", err)
	}
	if string(got) != string(want) {
		t.Errorf("content mismatch: got %q, want %q", got, want)
	}
}

func TestHTTPDownloader_Fetch_ServerError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	defer srv.Close()

	d := updater.NewHTTPDownloader()
	_, err := d.Fetch(srv.URL)
	if err == nil {
		t.Fatal("expected error for 404, got nil")
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

```
cd tray && go test ./updater/... -run TestHTTPDownloader -v
```

Expected: compilation error.

- [ ] **Step 3: Create downloader.go**

Create `tray/updater/downloader.go`:

```go
package updater

import (
	"fmt"
	"io"
	"net/http"
	"os"
)

// Downloader fetches a remote archive to a local temp file.
type Downloader interface {
	// Fetch downloads the archive at url and returns the path to a temp file.
	// The caller is responsible for removing the file when done.
	Fetch(url string) (path string, err error)
}

// HTTPDownloader downloads archives over HTTP using the stdlib client.
type HTTPDownloader struct{}

func NewHTTPDownloader() *HTTPDownloader { return &HTTPDownloader{} }

func (d *HTTPDownloader) Fetch(url string) (string, error) {
	resp, err := http.Get(url) //nolint:noctx
	if err != nil {
		return "", fmt.Errorf("download %s: %w", url, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("download %s: status %d", url, resp.StatusCode)
	}

	tmp, err := os.CreateTemp("", "scry2-update-*")
	if err != nil {
		return "", fmt.Errorf("create temp file: %w", err)
	}
	defer tmp.Close()

	if _, err := io.Copy(tmp, resp.Body); err != nil {
		os.Remove(tmp.Name())
		return "", fmt.Errorf("write download: %w", err)
	}

	return tmp.Name(), nil
}
```

- [ ] **Step 4: Run tests**

```
cd tray && go test ./updater/... -run TestHTTPDownloader -v
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
jj desc -m "feat: add updater/downloader.go — HTTP archive download"
jj new
```

---

## Task 5: extractor.go — tar.gz and zip extraction

**Files:**
- Create: `tray/updater/extractor.go`
- Create: `tray/updater/extractor_test.go`

- [ ] **Step 1: Write failing tests**

Create `tray/updater/extractor_test.go`:

```go
package updater_test

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"os"
	"path/filepath"
	"testing"

	"scry2/tray/updater"
)

func makeTarGz(t *testing.T, files map[string]string) string {
	t.Helper()
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	for name, content := range files {
		hdr := &tar.Header{Name: name, Mode: 0755, Size: int64(len(content))}
		tw.WriteHeader(hdr)
		tw.Write([]byte(content))
	}
	tw.Close()
	gz.Close()

	f, err := os.CreateTemp("", "test-*.tar.gz")
	if err != nil {
		t.Fatal(err)
	}
	f.Write(buf.Bytes())
	f.Close()
	t.Cleanup(func() { os.Remove(f.Name()) })
	return f.Name()
}

func makeZip(t *testing.T, files map[string]string) string {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for name, content := range files {
		w, _ := zw.Create(name)
		w.Write([]byte(content))
	}
	zw.Close()

	f, err := os.CreateTemp("", "test-*.zip")
	if err != nil {
		t.Fatal(err)
	}
	f.Write(buf.Bytes())
	f.Close()
	t.Cleanup(func() { os.Remove(f.Name()) })
	return f.Name()
}

func TestArchiveExtractor_TarGz(t *testing.T) {
	archive := makeTarGz(t, map[string]string{
		"install":     "#!/bin/sh\necho installed",
		"bin/scry_2": "binary content",
	})
	dest := t.TempDir()

	e := updater.NewArchiveExtractor()
	if err := e.Extract(archive, dest); err != nil {
		t.Fatalf("Extract: %v", err)
	}

	content, err := os.ReadFile(filepath.Join(dest, "install"))
	if err != nil {
		t.Fatalf("install file not found: %v", err)
	}
	if string(content) != "#!/bin/sh\necho installed" {
		t.Errorf("unexpected install content: %q", content)
	}

	info, err := os.Stat(filepath.Join(dest, "install"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode()&0100 == 0 {
		t.Error("install file should be executable")
	}
}

func TestArchiveExtractor_Zip(t *testing.T) {
	archive := makeZip(t, map[string]string{
		"install.bat":  "@echo off\necho installed",
		"bin/scry_2.bat": "bat content",
	})
	dest := t.TempDir()

	e := updater.NewArchiveExtractor()
	if err := e.Extract(archive, dest); err != nil {
		t.Fatalf("Extract: %v", err)
	}

	content, err := os.ReadFile(filepath.Join(dest, "install.bat"))
	if err != nil {
		t.Fatalf("install.bat not found: %v", err)
	}
	if string(content) != "@echo off\necho installed" {
		t.Errorf("unexpected install.bat content: %q", content)
	}
}

func TestArchiveExtractor_UnknownFormat(t *testing.T) {
	f, err := os.CreateTemp("", "test-*.bz2")
	if err != nil {
		t.Fatal(err)
	}
	f.WriteString("not a valid archive")
	f.Close()
	defer os.Remove(f.Name())

	e := updater.NewArchiveExtractor()
	if err := e.Extract(f.Name(), t.TempDir()); err == nil {
		t.Fatal("expected error for unknown format")
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

```
cd tray && go test ./updater/... -run TestArchiveExtractor -v
```

Expected: compilation error.

- [ ] **Step 3: Create extractor.go**

Create `tray/updater/extractor.go`:

```go
package updater

import (
	"archive/tar"
	"archive/zip"
	"compress/gzip"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// Extractor unpacks a downloaded archive into a destination directory.
type Extractor interface {
	Extract(archivePath, destDir string) error
}

// ArchiveExtractor handles tar.gz (Linux/macOS) and zip (Windows) archives.
type ArchiveExtractor struct{}

func NewArchiveExtractor() *ArchiveExtractor { return &ArchiveExtractor{} }

func (e *ArchiveExtractor) Extract(archivePath, destDir string) error {
	switch {
	case strings.HasSuffix(archivePath, ".tar.gz"):
		return extractTarGz(archivePath, destDir)
	case strings.HasSuffix(archivePath, ".zip"):
		return extractZip(archivePath, destDir)
	default:
		return fmt.Errorf("unsupported archive format: %s", archivePath)
	}
}

func extractTarGz(archivePath, destDir string) error {
	f, err := os.Open(archivePath)
	if err != nil {
		return err
	}
	defer f.Close()

	gz, err := gzip.NewReader(f)
	if err != nil {
		return fmt.Errorf("gzip reader: %w", err)
	}
	defer gz.Close()

	tr := tar.NewReader(gz)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return fmt.Errorf("tar read: %w", err)
		}
		if err := extractTarEntry(tr, hdr, destDir); err != nil {
			return err
		}
	}
	return nil
}

func extractTarEntry(r io.Reader, hdr *tar.Header, destDir string) error {
	// Strip the top-level directory component (e.g. "scry_2-v0.3.0-linux-x86_64/install" → "install").
	parts := strings.SplitN(hdr.Name, "/", 2)
	name := hdr.Name
	if len(parts) == 2 {
		name = parts[1]
	}
	if name == "" {
		return nil
	}

	target := filepath.Join(destDir, filepath.FromSlash(name))

	switch hdr.Typeflag {
	case tar.TypeDir:
		return os.MkdirAll(target, 0755)
	case tar.TypeReg:
		if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
			return err
		}
		f, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, os.FileMode(hdr.Mode)|0600)
		if err != nil {
			return err
		}
		defer f.Close()
		_, err = io.Copy(f, r)
		return err
	}
	return nil
}

func extractZip(archivePath, destDir string) error {
	zr, err := zip.OpenReader(archivePath)
	if err != nil {
		return fmt.Errorf("zip open: %w", err)
	}
	defer zr.Close()

	for _, entry := range zr.File {
		// Strip top-level directory component.
		parts := strings.SplitN(entry.Name, "/", 2)
		name := entry.Name
		if len(parts) == 2 {
			name = parts[1]
		}
		if name == "" {
			continue
		}

		target := filepath.Join(destDir, filepath.FromSlash(name))

		if entry.FileInfo().IsDir() {
			os.MkdirAll(target, 0755)
			continue
		}

		if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
			return err
		}
		rc, err := entry.Open()
		if err != nil {
			return err
		}
		f, err := os.Create(target)
		if err != nil {
			rc.Close()
			return err
		}
		_, err = io.Copy(f, rc)
		f.Close()
		rc.Close()
		if err != nil {
			return err
		}
	}
	return nil
}
```

- [ ] **Step 4: Run tests**

```
cd tray && go test ./updater/... -run TestArchiveExtractor -v
```

Expected: PASS — tar.gz, zip, and unknown format cases pass.

- [ ] **Step 5: Commit**

```bash
jj desc -m "feat: add updater/extractor.go — tar.gz and zip extraction"
jj new
```

---

## Task 6: installer — detached exec (Unix + Windows)

**Files:**
- Create: `tray/updater/installer_unix.go`
- Create: `tray/updater/installer_windows.go`
- Create: `tray/updater/installer_test.go`

- [ ] **Step 1: Write failing tests**

Create `tray/updater/installer_test.go`:

```go
package updater_test

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"scry2/tray/updater"
)

func TestRealInstaller_Run(t *testing.T) {
	dir := t.TempDir()

	// Create a fake install script that writes a sentinel file.
	var script string
	var scriptName string
	if runtime.GOOS == "windows" {
		scriptName = "install.bat"
		script = "@echo off\necho ran > " + filepath.Join(dir, "sentinel.txt")
	} else {
		scriptName = "install"
		script = "#!/bin/sh\ntouch " + filepath.Join(dir, "sentinel.txt")
	}
	scriptPath := filepath.Join(dir, scriptName)
	if err := os.WriteFile(scriptPath, []byte(script), 0755); err != nil {
		t.Fatal(err)
	}

	installer := updater.NewRealInstaller()
	if err := installer.Run(dir); err != nil {
		t.Fatalf("Run: %v", err)
	}

	// Give the detached script a moment to run.
	// (In real use the tray exits immediately after; here we just verify no error.)
	// The sentinel check is best-effort since the process is detached.
}
```

- [ ] **Step 2: Run tests to verify they fail**

```
cd tray && go test ./updater/... -run TestRealInstaller -v
```

Expected: compilation error.

- [ ] **Step 3: Create installer_unix.go**

Create `tray/updater/installer_unix.go`:

```go
//go:build !windows

package updater

import (
	"fmt"
	"os/exec"
	"path/filepath"
	"syscall"
)

// Installer runs the install script from an extracted release directory.
type Installer interface {
	Run(extractedDir string) error
}

// RealInstaller runs the platform install script detached from the tray process group.
type RealInstaller struct{}

func NewRealInstaller() *RealInstaller { return &RealInstaller{} }

func (i *RealInstaller) Run(extractedDir string) error {
	script := filepath.Join(extractedDir, "install")
	cmd := exec.Command(script)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start install script: %w", err)
	}
	// Do not Wait — tray exits immediately; install script runs independently.
	return nil
}
```

- [ ] **Step 4: Create installer_windows.go**

Create `tray/updater/installer_windows.go`:

```go
//go:build windows

package updater

import (
	"fmt"
	"os/exec"
	"path/filepath"
	"syscall"
)

// Installer runs the install script from an extracted release directory.
type Installer interface {
	Run(extractedDir string) error
}

// RealInstaller runs the platform install script detached from the tray process group.
type RealInstaller struct{}

func NewRealInstaller() *RealInstaller { return &RealInstaller{} }

func (i *RealInstaller) Run(extractedDir string) error {
	script := filepath.Join(extractedDir, "install.bat")
	cmd := exec.Command(script)
	cmd.SysProcAttr = &syscall.SysProcAttr{
		CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP,
	}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start install script: %w", err)
	}
	return nil
}
```

- [ ] **Step 5: Run tests**

```
cd tray && go test ./updater/... -run TestRealInstaller -v
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
jj desc -m "feat: add updater/installer — detached install script exec"
jj new
```

---

## Task 7: updater.go — orchestrator

**Files:**
- Create: `tray/updater/updater.go`
- Create: `tray/updater/updater_test.go`

- [ ] **Step 1: Write failing tests**

Create `tray/updater/updater_test.go`:

```go
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

	// After failure, menu should reset to "Update Now" (not stuck at "Updating...")
	time.Sleep(10 * time.Millisecond)
	if item.Title() != "Update Now (v0.3.0)" {
		t.Errorf("after download failure title = %q, want %q", item.Title(), "Update Now (v0.3.0)")
	}
}

func TestUpdater_ApplyUpdate_CallsInstaller(t *testing.T) {
	checker := &mockChecker{release: updater.Release{Version: "v0.3.0", ArchiveURL: "http://example.com/archive.tar.gz"}}
	installer := &mockInstaller{}
	item := newMockMenuItem()

	u := updater.New("v0.2.0", checker, &mockDownloader{path: "/tmp/fake.tar.gz"}, &mockExtractor{}, installer, item)
	u.CheckOnce()
	u.ApplyUpdate()

	if !installer.called {
		t.Error("expected installer.Run to have been called")
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
```

- [ ] **Step 2: Run tests to verify they fail**

```
cd tray && go test ./updater/... -run TestUpdater -v
```

Expected: compilation error.

- [ ] **Step 3: Create updater.go**

Create `tray/updater/updater.go`:

```go
package updater

import (
	"fmt"
	"os"
	"os/exec"
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

	pendingRelease *Release
	stopCh         chan struct{}
}

// New constructs an Updater. Inject real or mock implementations as needed.
func New(currentVersion string, checker ReleaseChecker, downloader Downloader, extractor Extractor, installer Installer, item MenuItem) *Updater {
	return &Updater{
		currentVersion: currentVersion,
		checker:        checker,
		downloader:     downloader,
		extractor:      extractor,
		installer:      installer,
		item:           item,
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

// ApplyUpdate downloads and installs the pending release, then calls os.Exit(0).
// If any step fails, the menu item is reset gracefully.
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

	os.Exit(0)
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
```

Note: `ApplyUpdate` calls `os.Exit(0)` on success. In tests, `mockInstaller` returns without error but the test does not reach `os.Exit` because the test calls `ApplyUpdate` with a mock installer — exit is only reached in production where `RealInstaller.Run` detaches the install script. In the `TestUpdater_ApplyUpdate_CallsInstaller` test the mock installer's `Run` returns `nil`, but `os.Exit(0)` is still called. To avoid killing the test process, split the exit into an injectable hook. Update `updater.go` to accept an `exitFn`:

Replace `updater.go` with this version that makes exit injectable for tests:

```go
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
		return
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
```

Also update `updater_test.go` — the `TestUpdater_ApplyUpdate_CallsInstaller` test needs to use `newWithExit` to inject a no-op exit. But `newWithExit` is unexported. Export it or make the test use a different approach.

The cleanest solution: add a `WithExitFn` option to `New`. Replace the test's `updater.New(...)` call with a builder that sets a no-op exit. Since the package is `updater`, expose `newWithExit` as a test helper by adding a file `export_test.go`:

Create `tray/updater/export_test.go`:

```go
package updater

// NewForTest constructs an Updater with an injectable exit function for testing.
func NewForTest(currentVersion string, checker ReleaseChecker, downloader Downloader, extractor Extractor, installer Installer, item MenuItem, exitFn func(int)) *Updater {
	return newWithExit(currentVersion, checker, downloader, extractor, installer, item, exitFn)
}
```

Update `TestUpdater_ApplyUpdate_CallsInstaller` in `updater_test.go` to use `updater.NewForTest`:

```go
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
```

- [ ] **Step 4: Run all updater tests**

```
cd tray && go test ./updater/... -v
```

Expected: PASS — all tests green.

- [ ] **Step 5: Commit**

```bash
jj desc -m "feat: add updater/updater.go — orchestrator with menu state and ticker"
jj new
```

---

## Task 8: Wire up in main.go

**Files:**
- Modify: `tray/main.go`

- [ ] **Step 1: Add the update menu item and wire the updater**

Replace `tray/main.go` with:

```go
package main

import (
	_ "embed"

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
	mUpdate := systray.AddMenuItem("Check for Updates", "Check for a newer version of Scry2")
	systray.AddSeparator()
	mQuit := systray.AddMenuItem("Quit", "Stop Scry2 and quit")

	backend.Start()
	backend.StartWatchdog(quitCh)

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
```

- [ ] **Step 2: Create the systray adapter**

The `systray.MenuItem` does not implement `updater.MenuItem` directly (it uses `ClickedCh` as a field, not a method). Add an adapter. Create `tray/systray_menu_item.go`:

```go
package main

import (
	"github.com/getlantern/systray"
)

// systrayMenuItem adapts *systray.MenuItem to the updater.MenuItem interface.
type systrayMenuItem struct {
	item *systray.MenuItem
}

func (s *systrayMenuItem) SetTitle(title string) { s.item.SetTitle(title) }
func (s *systrayMenuItem) Disable()              { s.item.Disable() }
func (s *systrayMenuItem) Enable()               { s.item.Enable() }
func (s *systrayMenuItem) ClickedCh() <-chan struct{} {
	return s.item.ClickedCh
}
```

- [ ] **Step 3: Build to verify it compiles**

```
cd tray && go build ./...
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
jj desc -m "feat: wire updater into tray main — add Update menu item"
jj new
```

---

## Task 9: Stamp version at build time

**Files:**
- Modify: `scripts/release`
- Modify: `.github/workflows/release.yml`

- [ ] **Step 1: Update scripts/release**

In `scripts/release`, find both `go build` lines and add the ldflags. The version is read from `mix.exs`. Add a helper near the top of the script after `cd "$(dirname "$0")/.."`:

```bash
# Extract version from mix.exs
VERSION=$(grep -oP '(?<=version: ")[^"]+' mix.exs)
```

Change both `go build` lines from:
```bash
(cd tray && go build -o ../scry2-tray .)
```
to:
```bash
(cd tray && go build -ldflags="-X 'scry2/tray/updater.CurrentVersion=${VERSION}'" -o ../scry2-tray .)
```

The Darwin case has the same `go build` line, so both need updating. The full changed section of `scripts/release`:

```bash
# Extract version from mix.exs
VERSION=$(grep -oP '(?<=version: ")[^"]+' mix.exs)

banner "Building tray binary"
case "$(uname -s)" in
  Linux)
    (cd tray && go build -ldflags="-X 'scry2/tray/updater.CurrentVersion=${VERSION}'" -o ../scry2-tray .)
    install_script="scripts/install"
    uninstall_script="scripts/uninstall"
    ;;
  Darwin)
    (cd tray && go build -ldflags="-X 'scry2/tray/updater.CurrentVersion=${VERSION}'" -o ../scry2-tray .)
    install_script="scripts/install-macos"
    uninstall_script="scripts/uninstall-macos"
    ;;
  *)
    echo "Error: unsupported platform $(uname -s)"
    exit 1
    ;;
esac
```

- [ ] **Step 2: Update .github/workflows/release.yml**

The workflow already extracts the version into a `VERSION` variable via the "Set version from tag" step (Python script that writes to `mix.exs`). The version is available via `${{ github.ref_name }}` (e.g. `v0.3.0`).

Find the two tray build steps:

```yaml
- name: Build tray binary (Linux/macOS)
  if: matrix.os != 'windows-latest'
  run: cd tray && go build -o ../scry2-tray .

- name: Build tray binary (Windows)
  if: matrix.os == 'windows-latest'
  shell: pwsh
  run: cd tray && go build -ldflags="-H windowsgui" -o ../scry2-tray.exe .
```

Replace with:

```yaml
- name: Build tray binary (Linux/macOS)
  if: matrix.os != 'windows-latest'
  run: cd tray && go build -ldflags="-X 'scry2/tray/updater.CurrentVersion=${{ github.ref_name }}'" -o ../scry2-tray .

- name: Build tray binary (Windows)
  if: matrix.os == 'windows-latest'
  shell: pwsh
  run: cd tray && go build -ldflags="-H windowsgui -X 'scry2/tray/updater.CurrentVersion=${{ github.ref_name }}'" -o ../scry2-tray.exe .
```

Note: `${{ github.ref_name }}` is `v0.3.0` (with the `v` prefix), matching the tag format used in `IsNewer` comparison.

- [ ] **Step 3: Verify local build stamps the version**

```bash
scripts/release
strings _build/prod/package/scry2-tray | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$'
```

Expected: prints the current version string from `mix.exs`.

- [ ] **Step 4: Commit**

```bash
jj desc -m "feat: stamp version into tray binary at build time via ldflags"
jj new
```

---

## Task 10: Run all tests and verify

- [ ] **Step 1: Run the full tray test suite**

```
cd tray && go test ./... -v
```

Expected: all tests PASS, no compilation errors or warnings.

- [ ] **Step 2: Run precommit**

From the repo root:

```
mix precommit
```

Expected: zero warnings, all tests pass.

- [ ] **Step 3: Final commit**

```bash
jj desc -m "chore: verify all tests pass post-auto-update implementation"
jj new
```
