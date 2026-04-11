# System Tray Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a cross-platform system tray companion (`scry2-tray`) that launches the Elixir backend and provides Open / Toggle Auto-start / Quit from the tray icon on Windows, macOS, and Linux.

**Architecture:** A small Go program in `tray/` uses `github.com/getlantern/systray` to show a tray icon. On launch it starts the backend via `bin/scry_2 start` (or `bin\scry_2.bat start` on Windows), then watches for unexpected crashes and restarts. The tray exe becomes the new entry point for all platform auto-start mechanisms, replacing the current direct-backend Registry Run key / LaunchAgent / systemd service.

**Tech Stack:** Go 1.22, `github.com/getlantern/systray` v1.2.2, `golang.org/x/sys` (Windows registry only). CGO required — each platform builds natively.

---

## File Map

**Create:**
- `tray/go.mod` — Go module definition
- `tray/go.sum` — dependency lockfile (generated)
- `tray/assets/icon.png` — 32×32 PNG tray icon
- `tray/main.go` — systray.Run, onReady, menu wiring
- `tray/backend.go` — start/stop/watchdog for Elixir process
- `tray/browser_windows.go` — `openBrowser` via `cmd /c start`
- `tray/browser_darwin.go` — `openBrowser` via `open`
- `tray/browser_linux.go` — `openBrowser` via `xdg-open`
- `tray/autostart_windows.go` — HKCU Run registry key
- `tray/autostart_darwin.go` — `~/Library/LaunchAgents/com.scry2.plist`
- `tray/autostart_linux.go` — `~/.config/autostart/scry2.desktop`
- `tray/autostart_linux_test.go` — unit tests for Linux autostart

**Modify:**
- `scripts/install` — remove systemd setup; copy tray binary; create XDG autostart on install
- `scripts/uninstall` — remove XDG autostart; kill tray process; remove systemd remnants
- `scripts/install-macos` — point LaunchAgent at tray binary instead of backend
- `scripts/uninstall-macos` — kill tray process
- `rel/overlays/install.bat` — copy tray exe; point Registry Run to tray exe; remove browser open
- `rel/overlays/uninstall.bat` — kill tray process; remove tray exe
- `.github/workflows/release.yml` — install Go + systray deps; build tray; include in archive

---

## Task 1: Scaffold the Go module

**Files:** Create `tray/go.mod`

- [ ] **Create `tray/go.mod`**

```
module scry2/tray

go 1.22

require (
	github.com/getlantern/systray v1.2.2
	golang.org/x/sys v0.21.0
)
```

- [ ] **Initialize the module and fetch dependencies**

```bash
cd tray && go mod tidy
```

Expected: `go.sum` created with hashes for `getlantern/systray` and `golang.org/x/sys`.

- [ ] **Commit**

```bash
jj desc -m "chore: scaffold tray Go module"
```

---

## Task 2: Create the tray icon

**Files:** Create `tray/assets/icon.png`

- [ ] **Generate a minimal 32×32 PNG icon**

Create `tray/gen_icon.go` (a standalone generator, not part of the binary):

```go
//go:build ignore

package main

import (
	"image"
	"image/color"
	"image/png"
	"os"
)

func main() {
	img := image.NewRGBA(image.Rect(0, 0, 32, 32))
	bg := color.RGBA{R: 30, G: 30, B: 46, A: 255}  // dark navy
	fg := color.RGBA{R: 137, G: 180, B: 250, A: 255} // blue

	for y := 0; y < 32; y++ {
		for x := 0; x < 32; x++ {
			img.Set(x, y, bg)
		}
	}

	// Simple "S" shape (5×7 pixel strokes at centre)
	pixels := [][2]int{
		{11, 8}, {12, 8}, {13, 8}, {14, 8}, {15, 8}, {16, 8}, {17, 8}, {18, 8}, {19, 8}, {20, 8},
		{10, 9}, {10, 10}, {10, 11}, {10, 12}, {10, 13},
		{11, 14}, {12, 14}, {13, 14}, {14, 14}, {15, 14}, {16, 14}, {17, 14}, {18, 14}, {19, 14}, {20, 14},
		{21, 15}, {21, 16}, {21, 17}, {21, 18}, {21, 19},
		{11, 20}, {12, 20}, {13, 20}, {14, 20}, {15, 20}, {16, 20}, {17, 20}, {18, 20}, {19, 20}, {20, 20},
	}
	for _, p := range pixels {
		img.Set(p[0], p[1], fg)
	}

	os.MkdirAll("assets", 0755)
	f, _ := os.Create("assets/icon.png")
	defer f.Close()
	png.Encode(f, img)
}
```

- [ ] **Run the generator**

```bash
cd tray && go run gen_icon.go
```

Expected: `tray/assets/icon.png` created (32×32, ~500 bytes).

- [ ] **Commit**

```bash
jj desc -m "chore: add tray icon asset"
```

---

## Task 3: Write `tray/backend.go`

**Files:** Create `tray/backend.go`

- [ ] **Write `tray/backend.go`**

```go
package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"time"

	"github.com/getlantern/systray"
)

var quitting bool

func backendBin() string {
	exe, _ := os.Executable()
	dir := filepath.Dir(exe)
	bin := filepath.Join(dir, "bin", "scry_2")
	if runtime.GOOS == "windows" {
		return bin + ".bat"
	}
	return bin
}

func startBackend() {
	exec.Command(backendBin(), "start").Start() //nolint:errcheck
	go watchdog()
}

func stopBackend() {
	exec.Command(backendBin(), "stop").Run() //nolint:errcheck
}

func isBackendRunning() bool {
	return exec.Command(backendBin(), "pid").Run() == nil
}

func watchdog() {
	time.Sleep(20 * time.Second) // allow initial startup
	for {
		time.Sleep(10 * time.Second)
		if quitting {
			return
		}
		if !isBackendRunning() {
			time.Sleep(2 * time.Second)
			if !quitting {
				exec.Command(backendBin(), "start").Start() //nolint:errcheck
				time.Sleep(20 * time.Second)
			}
		}
	}
}

func quit() {
	quitting = true
	stopBackend()
	systray.Quit()
}
```

- [ ] **Verify it compiles (Linux)**

```bash
cd tray && go build ./...
```

Expected: no errors.

- [ ] **Commit**

```bash
jj desc -m "feat: tray backend lifecycle manager with watchdog"
```

---

## Task 4: Write browser open helpers

**Files:** Create `tray/browser_windows.go`, `tray/browser_darwin.go`, `tray/browser_linux.go`

- [ ] **Write `tray/browser_windows.go`**

```go
//go:build windows

package main

import "os/exec"

func openBrowser(url string) {
	exec.Command("cmd", "/c", "start", url).Start() //nolint:errcheck
}
```

- [ ] **Write `tray/browser_darwin.go`**

```go
//go:build darwin

package main

import "os/exec"

func openBrowser(url string) {
	exec.Command("open", url).Start() //nolint:errcheck
}
```

- [ ] **Write `tray/browser_linux.go`**

```go
//go:build linux

package main

import "os/exec"

func openBrowser(url string) {
	exec.Command("xdg-open", url).Start() //nolint:errcheck
}
```

- [ ] **Verify all three compile**

```bash
cd tray && go build ./...
GOOS=windows go build ./... 2>/dev/null || true  # may fail without CGO cross-toolchain; that's fine
```

Expected: Linux build succeeds.

- [ ] **Commit**

```bash
jj desc -m "feat: cross-platform browser open helpers"
```

---

## Task 5: Write autostart helpers

**Files:** Create `tray/autostart_linux.go`, `tray/autostart_linux_test.go`, `tray/autostart_darwin.go`, `tray/autostart_windows.go`

### Linux (write test first)

- [ ] **Write `tray/autostart_linux_test.go`**

```go
//go:build linux

package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestAutoStartLinux(t *testing.T) {
	// Override desktopPath to use a temp dir
	tmp := t.TempDir()
	origDesktopPath := desktopPathFn
	desktopPathFn = func() string {
		return filepath.Join(tmp, "autostart", "scry2.desktop")
	}
	defer func() { desktopPathFn = origDesktopPath }()

	if IsAutoStartEnabled() {
		t.Fatal("expected disabled before any setup")
	}

	if err := SetAutoStart(true); err != nil {
		t.Fatalf("SetAutoStart(true): %v", err)
	}

	if !IsAutoStartEnabled() {
		t.Fatal("expected enabled after SetAutoStart(true)")
	}

	content, _ := os.ReadFile(desktopPathFn())
	if len(content) == 0 {
		t.Fatal("desktop file is empty")
	}

	if err := SetAutoStart(false); err != nil {
		t.Fatalf("SetAutoStart(false): %v", err)
	}

	if IsAutoStartEnabled() {
		t.Fatal("expected disabled after SetAutoStart(false)")
	}
}
```

- [ ] **Run test to confirm it fails**

```bash
cd tray && go test -run TestAutoStartLinux ./...
```

Expected: compile error — `desktopPathFn`, `IsAutoStartEnabled`, `SetAutoStart` not defined.

- [ ] **Write `tray/autostart_linux.go`**

```go
//go:build linux

package main

import (
	"fmt"
	"os"
	"path/filepath"
)

// desktopPathFn is a variable so tests can override it.
var desktopPathFn = func() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "autostart", "scry2.desktop")
}

func IsAutoStartEnabled() bool {
	_, err := os.Stat(desktopPathFn())
	return err == nil
}

func SetAutoStart(enabled bool) error {
	path := desktopPathFn()
	if !enabled {
		err := os.Remove(path)
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	exe, _ := os.Executable()
	content := fmt.Sprintf(`[Desktop Entry]
Type=Application
Name=Scry2
Exec=%s
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
`, exe)
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(content), 0644)
}
```

- [ ] **Run test to confirm it passes**

```bash
cd tray && go test -run TestAutoStartLinux ./...
```

Expected: PASS.

### macOS

- [ ] **Write `tray/autostart_darwin.go`**

```go
//go:build darwin

package main

import (
	"fmt"
	"os"
	"path/filepath"
)

const plistLabel = "com.scry2"

func plistPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "LaunchAgents", plistLabel+".plist")
}

func IsAutoStartEnabled() bool {
	_, err := os.Stat(plistPath())
	return err == nil
}

func SetAutoStart(enabled bool) error {
	path := plistPath()
	if !enabled {
		err := os.Remove(path)
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	exe, _ := os.Executable()
	content := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>%s</string>
    <key>ProgramArguments</key>
    <array>
        <string>%s</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>`, plistLabel, exe)
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(content), 0644)
}
```

### Windows

- [ ] **Write `tray/autostart_windows.go`**

```go
//go:build windows

package main

import (
	"os"

	"golang.org/x/sys/windows/registry"
)

const autoStartKeyName = "Scry2"
const autoStartKeyPath = `Software\Microsoft\Windows\CurrentVersion\Run`

func IsAutoStartEnabled() bool {
	k, err := registry.OpenKey(registry.CURRENT_USER, autoStartKeyPath, registry.QUERY_VALUE)
	if err != nil {
		return false
	}
	defer k.Close()
	_, _, err = k.GetStringValue(autoStartKeyName)
	return err == nil
}

func SetAutoStart(enabled bool) error {
	k, err := registry.OpenKey(registry.CURRENT_USER, autoStartKeyPath, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer k.Close()
	if !enabled {
		k.DeleteValue(autoStartKeyName) //nolint:errcheck — OK if already absent
		return nil
	}
	exe, _ := os.Executable()
	return k.SetStringValue(autoStartKeyName, `"`+exe+`"`)
}
```

- [ ] **Verify Linux tests still pass and code compiles**

```bash
cd tray && go test ./... && go build ./...
```

Expected: PASS, no errors.

- [ ] **Commit**

```bash
jj desc -m "feat: cross-platform autostart helpers"
```

---

## Task 6: Write `tray/main.go`

**Files:** Create `tray/main.go`

- [ ] **Write `tray/main.go`**

```go
package main

import (
	_ "embed"

	"github.com/getlantern/systray"
)

//go:embed assets/icon.png
var icon []byte

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

	startBackend()

	go func() {
		for {
			select {
			case <-mOpen.ClickedCh:
				openBrowser("http://localhost:4002")
			case <-mAutoStart.ClickedCh:
				if mAutoStart.Checked() {
					SetAutoStart(false)  //nolint:errcheck
					mAutoStart.Uncheck()
				} else {
					SetAutoStart(true)   //nolint:errcheck
					mAutoStart.Check()
				}
			case <-mQuit.ClickedCh:
				quit()
				return
			}
		}
	}()
}

func onExit() {}
```

- [ ] **Build the full binary on Linux**

```bash
cd tray && go build -o scry2-tray ./...
```

Expected: `tray/scry2-tray` binary created, no errors. Clean up after:

```bash
rm tray/scry2-tray
```

- [ ] **Commit**

```bash
jj desc -m "feat: tray main entry point and menu wiring"
```

---

## Task 7: Update Linux installer and uninstaller

**Files:** Modify `scripts/install`, `scripts/uninstall`

- [ ] **Rewrite `scripts/install`**

Replace the file with:

```bash
#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$HOME/.local/lib/scry_2"
DESKTOP_FILE="$HOME/.config/autostart/scry2.desktop"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing Scry2..."

# Stop existing tray and backend if running
if pgrep -x scry2-tray &>/dev/null; then
    echo "Stopping existing Scry2 tray..."
    pkill -x scry2-tray 2>/dev/null || true
    sleep 1
fi

# Copy release files
echo "Copying files to $INSTALL_DIR..."
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cp -r "$SCRIPT_DIR/." "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/scry2-tray"

# Enable autostart on login via XDG
mkdir -p "$(dirname "$DESKTOP_FILE")"
cat > "$DESKTOP_FILE" << EOF
[Desktop Entry]
Type=Application
Name=Scry2
Exec=$INSTALL_DIR/scry2-tray
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF

# Launch tray (which will start the backend)
echo "Starting Scry2..."
"$INSTALL_DIR/scry2-tray" &

echo ""
echo "Scry2 installed! It will start automatically on login."
echo "Access your stats at: http://localhost:4002"
echo ""
echo "Note: On GNOME, install 'gnome-shell-extension-appindicator' if the tray icon does not appear."
```

- [ ] **Rewrite `scripts/uninstall`**

```bash
#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$HOME/.local/lib/scry_2"
DESKTOP_FILE="$HOME/.config/autostart/scry2.desktop"

echo "Uninstalling Scry2..."

# Stop tray (it will also stop the backend on exit)
if pgrep -x scry2-tray &>/dev/null; then
    pkill -x scry2-tray 2>/dev/null || true
    sleep 2
fi

# Stop backend directly in case tray was not running
if [[ -f "$INSTALL_DIR/bin/scry_2" ]]; then
    "$INSTALL_DIR/bin/scry_2" stop 2>/dev/null || true
fi

# Remove autostart entry
rm -f "$DESKTOP_FILE"

# Remove install directory
if [[ -d "$INSTALL_DIR" ]]; then
    rm -rf "$INSTALL_DIR"
    echo "Removed $INSTALL_DIR"
fi

echo ""
echo "Scry2 uninstalled. Your data has been preserved:"
echo "  Config: ~/.config/scry_2/config.toml"
echo "  Data:   ~/.local/share/scry_2/"
echo ""
echo "To also remove your data: rm -rf ~/.local/share/scry_2/ ~/.config/scry_2/"
```

- [ ] **Commit**

```bash
jj desc -m "feat: update Linux installer to use tray binary"
```

---

## Task 8: Update macOS installer and uninstaller

**Files:** Modify `scripts/install-macos`, `scripts/uninstall-macos`

- [ ] **Rewrite `scripts/install-macos`**

```bash
#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$HOME/.local/lib/scry_2"
PLIST_LABEL="com.scry2"
PLIST_FILE="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing Scry2..."

# Unload existing launch agent if present
if launchctl list "$PLIST_LABEL" &>/dev/null; then
    echo "Stopping existing Scry2..."
    launchctl unload "$PLIST_FILE" 2>/dev/null || true
    pkill -x scry2-tray 2>/dev/null || true
    sleep 1
fi

# Copy release files
echo "Copying files to $INSTALL_DIR..."
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cp -r "$SCRIPT_DIR/." "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/scry2-tray"

# Write LaunchAgent pointing to tray binary
mkdir -p "$(dirname "$PLIST_FILE")"
cat > "$PLIST_FILE" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_DIR}/scry2-tray</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
EOF

# Load the agent (tray will start and launch the backend)
launchctl load "$PLIST_FILE"

echo ""
echo "Scry2 installed! It will start automatically on login."
echo "Access your stats at: http://localhost:4002"
```

- [ ] **Rewrite `scripts/uninstall-macos`**

```bash
#!/usr/bin/env bash
set -euo pipefail

PLIST_LABEL="com.scry2"
PLIST_FILE="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
INSTALL_DIR="$HOME/.local/lib/scry_2"

echo "Uninstalling Scry2..."

# Unload launch agent and stop tray
if launchctl list "$PLIST_LABEL" &>/dev/null; then
    launchctl unload "$PLIST_FILE" 2>/dev/null || true
fi
pkill -x scry2-tray 2>/dev/null || true

# Stop backend directly in case tray was not running
if [[ -f "$INSTALL_DIR/bin/scry_2" ]]; then
    "$INSTALL_DIR/bin/scry_2" stop 2>/dev/null || true
fi

# Remove plist and install directory
rm -f "$PLIST_FILE"
if [[ -d "$INSTALL_DIR" ]]; then
    rm -rf "$INSTALL_DIR"
    echo "Removed $INSTALL_DIR"
fi

echo ""
echo "Scry2 uninstalled. Your data has been preserved:"
echo "  Config: ~/.config/scry_2/config.toml"
echo "  Data:   ~/Library/Application Support/scry_2/"
echo ""
echo "To also remove your data:"
echo "  rm -rf ~/Library/Application\ Support/scry_2/ ~/.config/scry_2/"
```

- [ ] **Commit**

```bash
jj desc -m "feat: update macOS installer to use tray binary"
```

---

## Task 9: Update Windows installer and uninstaller

**Files:** Modify `rel/overlays/install.bat`, `rel/overlays/uninstall.bat`

- [ ] **Rewrite `rel/overlays/install.bat`**

```bat
@echo off
setlocal enabledelayedexpansion

echo Installing Scry2...

set INSTALL_DIR=%LOCALAPPDATA%\scry_2
set SCRIPT_DIR=%~dp0

REM Stop existing tray and backend if running
taskkill /f /im scry2-tray.exe 2>nul
if exist "%INSTALL_DIR%\bin\scry_2.bat" (
    call "%INSTALL_DIR%\bin\scry_2.bat" stop 2>nul
)
timeout /t 2 /nobreak >nul

REM Remove previous install
if exist "%INSTALL_DIR%" (
    rmdir /s /q "%INSTALL_DIR%"
)

REM Copy release to AppData\Local\scry_2
echo Copying files to %INSTALL_DIR%...
mkdir "%INSTALL_DIR%"
xcopy /e /i /q /h "%SCRIPT_DIR%." "%INSTALL_DIR%" >nul

REM Register autostart on login — point to tray, not backend
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" ^
    /v "Scry2" ^
    /t REG_SZ ^
    /d "\"%INSTALL_DIR%\scry2-tray.exe\"" ^
    /f >nul

REM Start the tray (it will launch the backend and open the browser)
echo Starting Scry2...
start "" /B "%INSTALL_DIR%\scry2-tray.exe"

echo.
echo Scry2 installed successfully!
echo It will start automatically on each login.
echo Open http://localhost:4002 in your browser to view your stats.
echo.
pause
```

- [ ] **Rewrite `rel/overlays/uninstall.bat`**

```bat
@echo off
echo Uninstalling Scry2...

REM Stop the tray (it will stop the backend on exit)
taskkill /f /im scry2-tray.exe 2>nul
timeout /t 2 /nobreak >nul

REM Also stop backend directly in case tray was not running
if exist "%LOCALAPPDATA%\scry_2\bin\scry_2.bat" (
    call "%LOCALAPPDATA%\scry_2\bin\scry_2.bat" stop 2>nul
    timeout /t 2 /nobreak >nul
)

REM Remove autostart registry entry
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v "Scry2" /f 2>nul

REM Remove the installation directory
if exist "%LOCALAPPDATA%\scry_2" (
    rmdir /s /q "%LOCALAPPDATA%\scry_2"
    echo Scry2 removed from %LOCALAPPDATA%\scry_2
)

echo.
echo Scry2 has been uninstalled.
echo.
echo   Removed:   %LOCALAPPDATA%\scry_2\  (install files and database)
echo   Preserved: %APPDATA%\scry_2\config.toml
echo.
echo To remove your config as well, delete: %APPDATA%\scry_2\
echo.
pause
```

- [ ] **Commit**

```bash
jj desc -m "feat: update Windows installer to use tray binary"
```

---

## Task 10: Update GitHub Actions release workflow

**Files:** Modify `.github/workflows/release.yml`

The existing `build` matrix already covers `ubuntu-latest`, `macos-latest`, and `windows-latest`. We need to add Go setup and tray build steps to each, plus include the tray binary in the package step.

- [ ] **Add Go setup and tray build to the build job** — insert after the `Build release` step and before the `Package release` steps:

```yaml
      - name: Set up Go
        uses: actions/setup-go@v5
        with:
          go-version: '1.22'
          cache-dependency-path: tray/go.sum

      - name: Install tray system dependencies (Linux)
        if: matrix.os == 'ubuntu-latest'
        run: sudo apt-get install -y libayatana-appindicator3-dev

      - name: Build tray binary (Linux/macOS)
        if: matrix.os != 'windows-latest'
        run: cd tray && go build -o ../scry2-tray ./...

      - name: Build tray binary (Windows)
        if: matrix.os == 'windows-latest'
        run: cd tray && go build -ldflags="-H windowsgui" -o ../scry2-tray.exe ./...
```

- [ ] **Include tray binary in each package step**

In the `Package release (Linux)` step, add after `cp -r _build/prod/rel/scry_2/. "$ARCHIVE/"`:

```yaml
          cp scry2-tray "$ARCHIVE/scry2-tray"
```

In the `Package release (macOS)` step, add after `cp -r _build/prod/rel/scry_2/. "$ARCHIVE/"`:

```yaml
          cp scry2-tray "$ARCHIVE/scry2-tray"
```

In the `Package release (Windows)` step (PowerShell), add after `Copy-Item -Recurse "_build\prod\rel\scry_2\*" "$ARCHIVE\"`:

```powershell
          Copy-Item "scry2-tray.exe" "$ARCHIVE\scry2-tray.exe"
```

- [ ] **Commit**

```bash
jj desc -m "ci: build and package scry2-tray in release workflow"
```

---

## Task 11: Final build smoke test and jj description

- [ ] **Run a full local build on Linux to confirm everything compiles**

```bash
cd tray && go test ./... && go build ./...
rm -f scry2-tray
```

Expected: all tests pass, binary builds cleanly.

- [ ] **Run `mix precommit` to confirm no Elixir regressions**

```bash
mix precommit
```

Expected: no warnings, no test failures.

- [ ] **Final commit description**

```bash
jj desc -m "feat: cross-platform system tray companion (scry2-tray)"
```

---

## Verification

1. **Linux (KDE/XFCE):** Run `scripts/install` on the built release; confirm tray icon in taskbar; Open launches browser; Toggle Auto-start creates/removes `~/.config/autostart/scry2.desktop`; Quit stops backend (`$INSTALL_DIR/bin/scry_2 pid` fails after Quit)
2. **macOS:** Run `scripts/install-macos`; confirm NSStatusItem in menu bar; LaunchAgent plist appears at `~/Library/LaunchAgents/com.scry2.plist` and toggles correctly
3. **Windows:** Run `install.bat`; confirm system tray icon; `reg query HKCU\...\Run /v Scry2` shows `scry2-tray.exe`; toggles and Quit work
4. **Watchdog:** Kill the Elixir backend process directly (`kill <pid>`) — confirm tray restarts it within ~30s
5. **GNOME:** Note that `gnome-shell-extension-appindicator` is required; test on KDE/XFCE if GNOME is unavailable
