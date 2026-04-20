# Scry2 Developer Guide

## Requirements

- Elixir 1.18+ and Erlang/OTP 27+
- Go 1.22+ (for the `scry2-tray` system tray binary)
- [mise](https://mise.jdx.dev/) (recommended for toolchain management)

## Setup

```bash
mix setup          # install deps, create DB, build assets
mix phx.server     # start dev server at http://localhost:4002
mix test           # run tests
mix precommit      # compile --warnings-as-errors, format, test — run before committing
```

## Dev Service

Install a persistent systemd user service so the dev server survives terminal sessions:

```bash
scripts/install-dev                               # install and start the service
systemctl --user start scry-2-dev                 # start
systemctl --user stop scry-2-dev                  # stop
journalctl --user -u scry-2-dev -f                # logs
iex --name repl@127.0.0.1 --remsh scry_2_dev@127.0.0.1   # remote REPL
```

Disconnect the REPL with `Ctrl+\` (leaves the server running).

## System Tray Binary

The `scry2-tray` companion binary provides the system tray icon on Linux, macOS,
and Windows. It lives in `tray/` as a separate Go module (`scry2/tray`, Go 1.22).

### What it does

- Displays a tray icon with four menu items: **Open**, **Open Settings**, **Auto-start on login**, **Quit**
- Starts the Elixir backend subprocess on launch and opens the dashboard URL in the
  default browser when the user clicks **Open** (or the Settings page via **Open Settings**)
- Runs a watchdog goroutine that polls the backend every 10 seconds and restarts it
  if it has crashed — with one exception: if `$DATA_DIR/apply.lock` is present and
  fresh, the watchdog skips the restart. This coordinates with the Elixir self-updater
  (see `Scry2.SelfUpdate` and ADR-033), which takes the backend down intentionally
  during an apply.
- Manages login persistence on each platform (XDG `.desktop` on Linux, `LaunchAgent`
  plist on macOS, Registry key on Windows)

**The tray has no update logic.** Self-update orchestration lives in the Elixir
backend (`Scry2.SelfUpdate`) and is surfaced in the Settings LiveView.

The tray binary is the **single entry point** for all platforms in a release install.
Users never call `bin/scry_2` directly — the tray starts and supervises it.

### Communication with the Elixir backend

The tray communicates with the backend exclusively through subprocess commands:

| Command | Purpose |
|---------|---------|
| `bin/scry_2 start` | Start the backend (fire-and-forget, `.Start()`) |
| `bin/scry_2 pid` | Health check — exits 0 if running, 1 if not |
| `bin/scry_2 stop` | Graceful shutdown |

The tray resolves the backend binary path relative to its own executable:
`<tray-dir>/bin/scry_2` (or `bin/scry_2.bat` on Windows).

### Watchdog

The watchdog goroutine in `backend.go` runs for the lifetime of the tray process:

1. **20-second grace period** after initial `start` (let the BEAM fully boot)
2. **Poll every 10 seconds** — call `pid`; if it returns non-zero the backend has crashed
3. **2-second restart delay** — brief pause before calling `start` again
4. **20-second grace period** after each restart
5. **Responds to `quitCh`** — closes cleanly when the user clicks Quit

The watchdog interval and grace periods are configurable fields on `RealBackend`
(used by tests to run at 100 ms instead of 10 s — see Testing below).

### Platform differences

| Platform | Autostart mechanism | Build notes |
|----------|-------------------|-------------|
| Linux | `~/.config/autostart/scry2.desktop` | Requires `libayatana-appindicator3-dev` |
| macOS | `~/Library/LaunchAgents/com.scry2.plist` | — |
| Windows | `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` | Add `-ldflags="-H windowsgui"` to suppress console window |

Linux system dependency:

```bash
sudo apt-get install -y libayatana-appindicator3-dev
```

### Building

```bash
cd tray

# Linux / macOS
go build -o scry2-tray ./...

# Windows (suppress console window)
go build -ldflags="-H windowsgui" -o scry2-tray.exe ./...
```

The tray binary is built automatically for all three platforms by the GitHub Actions
release workflow. Manual builds are only needed for ad-hoc testing of the binary
itself — local Elixir development does not require the tray binary at all.

### Local development

For normal Elixir development, run the backend directly:

```bash
mix phx.server    # or: systemctl --user start scry-2-dev
```

The tray binary is only needed when testing the full install experience — i.e. the
tray icon, the backend lifecycle, or the autostart toggle. In that case, build a
release first (`scripts/release`) and then run `scry2-tray` from the install
directory.

### Testing

All tests live in `tray/` alongside the code they cover. Run them with:

```bash
cd tray && go test ./...
```

CI runs `go test ./...` on Linux, macOS, and Windows on every push
(`.github/workflows/tray-ci.yml`).

#### Test design

The tray code is designed for testability through **injectable variables and struct
fields**. Nothing in the production code imports a test package — the hooks are
plain Go variables that tests override with `defer` to restore them.

**Autostart — path/key injection**

Each platform's autostart file exposes a variable for the storage path, so tests
redirect writes to a temp location without touching the real system:

```go
// Linux (autostart_linux.go)
var desktopPathFn = func() string { return "~/.config/autostart/scry2.desktop" }

// macOS (autostart_darwin.go)
var plistPathFn = func() string { return "~/Library/LaunchAgents/com.scry2.plist" }

// Windows (autostart_windows.go)
var autoStartKeyPath  = `Software\Microsoft\Windows\CurrentVersion\Run`
var autoStartValueName = "Scry2"
```

Tests override these before calling `IsAutoStartEnabled()` / `SetAutoStart()`:

```go
tmp := t.TempDir()
origFn := plistPathFn
plistPathFn = func() string { return filepath.Join(tmp, "com.scry2.plist") }
defer func() { plistPathFn = origFn }()
```

**Browser opener — command injection**

Each platform's browser file exposes `browserCmdFn`, a variable that returns the
`*exec.Cmd` to run. Tests inspect the returned command's `Args` without executing it:

```go
cmd := browserCmdFn("http://localhost:4002")
// assert cmd.Args[0] == "xdg-open" (Linux), "open" (macOS), "cmd" (Windows)
```

**Backend lifecycle — fake backend binary**

`backend.go` exposes `RealBackend`, a struct with injectable fields:

```go
type RealBackend struct {
    binPath          string
    extraEnv         []string        // env vars injected into every subprocess
    WatchdogInterval time.Duration   // default 10s; tests use 100ms
    GracePeriod      time.Duration   // default 20s; tests use 100ms
    RestartDelay     time.Duration   // default 2s;  tests use 100ms
}
```

Tests use `fakebackend` — a tiny Go binary in `tray/testutil/fakebackend/` that
mimics the `bin/scry_2` command interface:

| Subcommand | Behaviour |
|-----------|-----------|
| `start` | Creates `$FAKE_BACKEND_PIDFILE`; if `FAKE_BACKEND_CRASH_AFTER=N` is set, sleeps N seconds then deletes the file |
| `pid` | Exits 0 if `$FAKE_BACKEND_PIDFILE` exists, exits 1 otherwise |
| `stop` | Deletes `$FAKE_BACKEND_PIDFILE` |

`TestMain` in `backend_test.go` compiles the fake binary before any tests run so
`go test ./...` is fully self-contained — no pre-built binary required:

```go
func TestMain(m *testing.M) {
    fakeBackendBin = filepath.Join(t.TempDir(), "fakebackend")
    exec.Command("go", "build", "-o", fakeBackendBin, "./testutil/fakebackend").Run()
    os.Exit(m.Run())
}
```

A typical backend test:

```go
b := &RealBackend{
    binPath:          fakeBackendBin,
    extraEnv:         []string{"FAKE_BACKEND_PIDFILE=" + pidFile},
    WatchdogInterval: 100 * time.Millisecond,
    GracePeriod:      100 * time.Millisecond,
    RestartDelay:     100 * time.Millisecond,
}
```

#### Test coverage

| File | Tests | What they cover |
|------|-------|----------------|
| `autostart_linux_test.go` | `TestAutoStartLinux` | `.desktop` file created, removed, idempotent |
| `autostart_darwin_test.go` | `TestAutoStartDarwin` | plist created, removed, idempotent (macOS runner only) |
| `autostart_windows_test.go` | `TestAutoStartWindows` | Registry value created, removed, idempotent (Windows runner only) |
| `backend_test.go` | `TestStart`, `TestStop`, `TestWatchdogRestarts` | Subprocess start/stop, watchdog restart after crash |
| `browser_linux_test.go` | `TestOpenBrowserLinux` | `browserCmdFn` produces `xdg-open <url>` |
| `browser_darwin_test.go` | `TestOpenBrowserDarwin` | `browserCmdFn` produces `open <url>` |
| `browser_windows_test.go` | `TestOpenBrowserWindows` | `browserCmdFn` produces `cmd /c start <url>` |

#### Adding new tests

- **New autostart test:** follow the path-injection pattern in the existing test for
  your platform. Use `t.TempDir()` for file-based tests; use a throwaway
  `HKCU\Software\scry2-test-<timestamp>` key for Windows registry tests.
- **New backend/watchdog test:** construct a `RealBackend` with `fakeBackendBin`,
  short intervals, and a `FAKE_BACKEND_PIDFILE` in `t.TempDir()`.
- **New browser test:** call `browserCmdFn` directly and assert on `cmd.Args`.
- **Platform-only tests:** guard with the appropriate build tag
  (`//go:build linux`, `//go:build darwin`, `//go:build windows`) so they only
  compile and run on the matching CI runner.

## Self-Update

`Scry2.SelfUpdate` owns the end-to-end update pipeline: hourly Oban cron check
against GitHub Releases → `:persistent_term` cache (1h TTL) + durable storage
via `Settings.Entry` → on "Apply update", the `Scry2.SelfUpdate.Updater`
GenServer runs a state machine (`preparing → downloading → extracting → handing_off`)
that downloads the archive, verifies against `SHA256SUMS`, extracts with
per-entry validation (rejects `..` traversal, symlinks, absolute paths), writes
`$DATA_DIR/apply.lock`, spawns the detached installer, and calls
`System.stop/0`. The installer replaces files, removes the apply lock, and
relaunches the tray.

UI lives in Settings (`/settings` → Updates card). Live phase rendering is
driven by PubSub broadcasts on `updates:progress`.

The subsystem is compile-time gated on `:prod` — dev and test runs are inert.
See ADR-033 and `specs/2026-04-20-elixir-self-update-design.md` for the full
design, and `lib/scry_2/self_update/` for the modules.

**To dev-test the UI flow:** populate the cache manually in an IEx session,
then visit `/settings`:

```elixir
Scry2.SelfUpdate.UpdateChecker.put_cache(%{
  tag: "v99.0.0",
  version: "99.0.0",
  published_at: "2026-04-20T12:00:00Z",
  html_url: "https://github.com/shawnmccool/scry_2/releases/tag/v99.0.0",
  body: "Test release"
})
```

The Updates card will show `99.0.0 available`. Clicking "Apply update" will
attempt a real download against GitHub Releases — do this only with a valid
tag in prod.

## Releasing

Releases are built automatically by GitHub Actions when a version tag is pushed.
Use the `scripts/tag-release` script to bump the version and trigger a release:

```bash
scripts/tag-release 0.2.0
```

This will:
1. Validate the version is semver
2. Bump `version:` in `mix.exs`
3. Describe the jj change as `chore: release v0.2.0`
4. Create a `v0.2.0` git tag
5. Push the bookmark and tag to the remote

GitHub Actions then builds Linux, macOS, and Windows release archives (including
the tray binary for each platform), generates per-platform
`scry_2-<tag>-<platform>-x86_64-SHA256SUMS` files consumed by the in-app
updater, and publishes everything to the [Releases page](../../releases).

To build a release locally (without publishing):

```bash
MIX_ENV=prod mix assets.deploy && MIX_ENV=prod mix release
# output: _build/prod/rel/scry_2/
```

## Architecture

See `CLAUDE.md` for bounded context layout, data model, and architectural
decision records under `decisions/`.
