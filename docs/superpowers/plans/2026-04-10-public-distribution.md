# Public Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Package Scry2 as self-contained cross-platform releases (Windows, macOS, Linux) distributed via GitHub Releases, with platform-aware first-run configuration and OS autostart.

**Architecture:** Elixir `mix release` bundles the BEAM VM. GitHub Actions builds on native runners for each platform. Platform install scripts handle autostart (systemd / launchd / registry). First-run config generation writes a minimal `config.toml` with a generated `secret_key_base` and platform-appropriate data paths.

**Tech Stack:** Elixir mix release, GitHub Actions (`erlef/setup-beam`), systemd (Linux), launchd (macOS), Windows registry, TOML

**Spec:** `/home/shawn/.claude/plans/sparkling-herding-parrot.md`

---

## Files to Create / Modify

| File | Action |
|------|--------|
| `mix.exs` | Add `releases` config, fix `visualizer` dep |
| `config/runtime.exs` | Remove mandatory env vars, TOML fallback, localhost binding |
| `lib/scry_2/config.ex` | Platform-aware paths, `cache_dir` key, first-run init |
| `lib/scry_2/mtga_log_ingestion/locate_log_file.ex` | Add Windows candidate path |
| `test/scry_2/config_test.exs` | Tests for first-run init and `cache_dir` key |
| `rel/overlays/install.bat` | Create — Windows install script (bundled via release overlay) |
| `rel/overlays/uninstall.bat` | Create — Windows uninstall script |
| `scripts/install` | Create — Linux release install/autostart |
| `scripts/uninstall` | Create — Linux release uninstall |
| `scripts/install-macos` | Create — macOS install/autostart via launchd |
| `scripts/uninstall-macos` | Create — macOS uninstall |
| `.github/workflows/release.yml` | Create — matrix build + GitHub Release upload |
| `README.md` | Create — public-facing docs |
| `LICENSE` | Create — MIT license |

---

## Task 1: Fix `visualizer` dep and add `releases` config to `mix.exs`

**Files:**
- Modify: `mix.exs`

- [ ] **Step 1: Add `only: :dev` to the `visualizer` dep**

In `mix.exs`, find line 75:
```elixir
{:visualizer, path: "../visualizer"}
```
Change to:
```elixir
{:visualizer, path: "../visualizer", only: :dev}
```

- [ ] **Step 2: Add a `releases/0` function and reference it in `project/0`**

Add to the `project/0` keyword list (after `listeners: [Phoenix.CodeReloader]`):
```elixir
releases: releases()
```

Add this private function at the end of `Scry2.MixProject`:
```elixir
defp releases do
  [
    scry_2: [
      include_executables_for: [:unix, :windows]
    ]
  ]
end
```

- [ ] **Step 3: Verify `mix deps.get --only prod` succeeds**

```bash
MIX_ENV=prod mix deps.get --only prod
```
Expected: fetches deps without error; no mention of `visualizer` or `tidewave`.

- [ ] **Step 4: Commit**

```bash
jj desc -m "chore: fix visualizer dev-only dep and add releases config"
```

---

## Task 2: Rewrite `runtime.exs` for self-contained release

The current `runtime.exs` raises if `DATABASE_PATH` or `SECRET_KEY_BASE` env vars are missing. For a local desktop app, these come from the generated `config.toml`, not env vars. We also bind to localhost instead of all interfaces, and always enable the server when running as a release.

**Files:**
- Modify: `config/runtime.exs`

- [ ] **Step 1: Replace the prod block in `config/runtime.exs`**

Replace the entire file content with:

```elixir
import Config

# Enables the Phoenix HTTP server when the PHX_SERVER env var is set,
# or automatically when running as a mix release (RELEASE_NAME is set
# by the release launcher).
if System.get_env("PHX_SERVER") || System.get_env("RELEASE_NAME") do
  config :scry_2, Scry2Web.Endpoint, server: true
end

if config_env() == :prod do
  config :scry_2, Scry2Web.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT", "4002"))]

  # ── Bootstrap config resolution ─────────────────────────────────────────
  # Read config.toml if present. On first run it may not exist yet —
  # Scry2.Config.load!/0 will generate it during Application.start/2.
  toml_path =
    case :os.type() do
      {:win32, _} ->
        Path.join([
          System.get_env("APPDATA") || System.user_home!(),
          "scry_2",
          "config.toml"
        ])

      _ ->
        Path.expand("~/.config/scry_2/config.toml")
    end

  toml =
    with {:ok, contents} <- File.read(toml_path),
         {:ok, parsed} <- Toml.decode(contents) do
      parsed
    else
      _ -> %{}
    end

  # Platform-appropriate default database path (used on first run before
  # config.toml exists).
  default_db_path =
    case :os.type() do
      {:win32, _} ->
        Path.join([
          System.get_env("LOCALAPPDATA") || System.user_home!(),
          "scry_2",
          "scry_2.db"
        ])

      {:unix, :darwin} ->
        Path.join([System.user_home!(), "Library", "Application Support", "scry_2", "scry_2.db"])

      _ ->
        Path.expand("~/.local/share/scry_2/scry_2.db")
    end

  database_path =
    System.get_env("DATABASE_PATH") ||
      get_in(toml, ["database", "path"]) ||
      default_db_path

  config :scry_2, Scry2.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5"),
    busy_timeout: 500

  # Secret key base: env var → TOML → random.
  # On first boot the TOML doesn't exist yet, so a random key is used for
  # that one boot. Scry2.Config.load!/0 writes the TOML (with a stable key)
  # during Application.start/2, so all subsequent boots use the persisted key.
  # For a localhost-only app this one-boot inconsistency is harmless
  # (no persistent sessions are lost; LiveView just reconnects).
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      toml["secret_key_base"] ||
      Base.encode64(:crypto.strong_rand_bytes(64))

  config :scry_2, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :scry_2, Scry2Web.Endpoint,
    url: [host: "localhost", port: 4002, scheme: "http"],
    http: [
      # Bind to localhost only — this is a local desktop tool, not a server.
      ip: {127, 0, 0, 1}
    ],
    secret_key_base: secret_key_base
end
```

- [ ] **Step 2: Verify the release builds without env vars**

```bash
MIX_ENV=prod MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix assets.deploy && MIX_ENV=prod mix release --overwrite
```
Expected: release builds successfully in `_build/prod/rel/scry_2/`.

- [ ] **Step 3: Commit**

```bash
jj desc -m "fix: make release self-contained — no mandatory env vars, localhost binding"
```

---

## Task 3: Add `cache_dir`, platform paths, and first-run init to `Scry2.Config`

**Files:**
- Modify: `lib/scry_2/config.ex`
- Modify: `test/scry_2/config_test.exs`

- [ ] **Step 1: Write failing tests for first-run init and `cache_dir`**

Add to `test/scry_2/config_test.exs`, after the existing `describe` block:

```elixir
describe "first-run config generation" do
  setup do
    tmp = Path.join(System.tmp_dir!(), "scry_2_test_#{:erlang.unique_integer([:positive])}.toml")
    Application.put_env(:scry_2, :config_path_override, tmp)
    Application.put_env(:scry_2, :skip_user_config, false)

    on_exit(fn ->
      File.rm(tmp)
      Application.delete_env(:scry_2, :config_path_override)
      Application.put_env(:scry_2, :skip_user_config, true)
    end)

    {:ok, tmp_path: tmp}
  end

  test "writes config.toml on first run when none exists", %{tmp_path: tmp} do
    refute File.exists?(tmp)
    :ok = Config.load!()
    assert File.exists?(tmp)
  end

  test "generated config contains secret_key_base", %{tmp_path: tmp} do
    :ok = Config.load!()
    {:ok, contents} = File.read(tmp)
    assert contents =~ "secret_key_base"
  end

  test "generated config contains database path", %{tmp_path: tmp} do
    :ok = Config.load!()
    {:ok, contents} = File.read(tmp)
    assert contents =~ "scry_2.db"
  end

  test "does not overwrite existing config on second load", %{tmp_path: tmp} do
    :ok = Config.load!()
    {:ok, original} = File.read(tmp)
    :ok = Config.load!()
    {:ok, second} = File.read(tmp)
    assert original == second
  end
end

describe "cache_dir key" do
  setup do
    Application.put_env(:scry_2, :skip_user_config, true)
    :ok = Config.load!()
  end

  test "cache_dir has a non-nil default" do
    assert Config.get(:cache_dir) != nil
  end

  test "cache_dir is an absolute path" do
    assert Config.get(:cache_dir) |> String.starts_with?("/") or
             String.match?(Config.get(:cache_dir), ~r/^[A-Z]:\\/)
  end
end
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
mix test test/scry_2/config_test.exs
```
Expected: failures on first-run and cache_dir tests; existing tests still pass.

- [ ] **Step 3: Rewrite `lib/scry_2/config.ex`**

```elixir
defmodule Scry2.Config do
  @moduledoc """
  Loads and serves application configuration from the user's
  TOML config file, falling back to application environment defaults.

  Call `load!/0` once at startup (before the supervision tree).
  Use `get/1` anywhere to read a config value from `:persistent_term`.

  On first run, if no config file exists, `load!/0` generates a minimal
  bootstrap config with a random `secret_key_base` and platform-appropriate
  data paths, then writes it to the config path before loading.

  Config file locations:
  - Linux/macOS: `~/.config/scry_2/config.toml`
  - Windows:     `%APPDATA%\\scry_2\\config.toml`
  """

  @type key ::
          :database_path
          | :cache_dir
          | :mtga_logs_player_log_path
          | :mtga_logs_poll_interval_ms
          | :mtga_self_user_id
          | :cards_lands17_url
          | :cards_refresh_cron
          | :cards_scryfall_bulk_url
          | :image_cache_dir
          | :start_watcher
          | :start_importer
          | :mtga_data_dir

  @doc """
  Loads configuration from TOML and stores it in `:persistent_term`.
  Generates a bootstrap config.toml on first run if none exists.
  Must be called once before any `get/1` calls — at the top of
  `Application.start/2`, before the children list.
  """
  @spec load!() :: :ok
  def load! do
    unless Application.get_env(:scry_2, :skip_user_config, false) do
      init_if_needed!()
    end

    :persistent_term.put({__MODULE__, :config}, load_config())
    :ok
  end

  @spec get(key()) :: term()
  def get(key) do
    :persistent_term.get({__MODULE__, :config}) |> Map.get(key)
  end

  # ── First-run init ───────────────────────────────────────────────────────

  defp init_if_needed! do
    path = config_path()

    unless File.exists?(path) do
      File.mkdir_p!(Path.dirname(path))
      secret_key_base = Base.encode64(:crypto.strong_rand_bytes(64))
      data_dir = platform_data_dir()

      contents = """
      # Scry2 bootstrap configuration — generated on first run.
      # To customize settings, use the in-app Settings page.
      # For all available options, see:
      # https://github.com/shawn/scry_2/blob/main/defaults/scry_2.toml

      secret_key_base = "#{secret_key_base}"

      [database]
      path = "#{Path.join(data_dir, "scry_2.db")}"

      [cache]
      dir = "#{Path.join(data_dir, "cache/")}"
      """

      File.write!(path, contents)
    end
  end

  # ── Platform helpers ─────────────────────────────────────────────────────

  defp config_path do
    Application.get_env(:scry_2, :config_path_override) ||
      case :os.type() do
        {:win32, _} ->
          Path.join([
            System.get_env("APPDATA") || System.user_home!(),
            "scry_2",
            "config.toml"
          ])

        _ ->
          Path.expand("~/.config/scry_2/config.toml")
      end
  end

  defp platform_data_dir do
    case :os.type() do
      {:win32, _} ->
        Path.join([System.get_env("LOCALAPPDATA") || System.user_home!(), "scry_2"])

      {:unix, :darwin} ->
        Path.join([System.user_home!(), "Library", "Application Support", "scry_2"])

      _ ->
        Path.expand("~/.local/share/scry_2")
    end
  end

  # ── Config loading ───────────────────────────────────────────────────────

  defp load_config do
    data_dir = platform_data_dir()

    defaults = %{
      database_path:
        Path.expand(
          get_in(Application.get_env(:scry_2, Scry2.Repo), [:database]) ||
            Path.join(data_dir, "scry_2.db")
        ),
      cache_dir: Path.join(data_dir, "cache/"),
      mtga_logs_player_log_path: nil,
      mtga_logs_poll_interval_ms: 500,
      mtga_self_user_id: nil,
      cards_lands17_url: "https://17lands-public.s3.amazonaws.com/analysis_data/cards/cards.csv",
      cards_refresh_cron: "0 4 * * *",
      cards_scryfall_bulk_url: "https://api.scryfall.com/bulk-data/default-cards",
      image_cache_dir: Path.join(data_dir, "cache/images/"),
      start_watcher: Application.get_env(:scry_2, :start_watcher, true),
      start_importer: Application.get_env(:scry_2, :start_importer, true),
      mtga_data_dir: nil
    }

    if Application.get_env(:scry_2, :skip_user_config, false) do
      defaults
    else
      load_toml(defaults)
    end
  end

  defp load_toml(defaults) do
    path = config_path()

    case File.read(path) do
      {:ok, contents} ->
        case Toml.decode(contents) do
          {:ok, toml} -> merge_toml(defaults, toml)
          {:error, _} -> defaults
        end

      {:error, _} ->
        defaults
    end
  end

  defp merge_toml(defaults, toml) do
    cache_dir =
      expand(get_in(toml, ["cache", "dir"])) ||
        defaults.cache_dir

    %{
      database_path: expand(get_in(toml, ["database", "path"])) || defaults.database_path,
      cache_dir: cache_dir,
      mtga_logs_player_log_path:
        expand(get_in(toml, ["mtga_logs", "player_log_path"])) ||
          defaults.mtga_logs_player_log_path,
      mtga_logs_poll_interval_ms:
        get_in(toml, ["mtga_logs", "poll_interval_ms"]) ||
          defaults.mtga_logs_poll_interval_ms,
      mtga_self_user_id:
        get_in(toml, ["mtga_logs", "self_user_id"]) || defaults.mtga_self_user_id,
      cards_lands17_url: get_in(toml, ["cards", "lands17_url"]) || defaults.cards_lands17_url,
      cards_refresh_cron: get_in(toml, ["cards", "refresh_cron"]) || defaults.cards_refresh_cron,
      cards_scryfall_bulk_url:
        get_in(toml, ["cards", "scryfall_bulk_url"]) || defaults.cards_scryfall_bulk_url,
      image_cache_dir:
        expand(get_in(toml, ["images", "cache_dir"])) ||
          Path.join(cache_dir, "images/"),
      start_watcher:
        value_or_default(get_in(toml, ["workers", "start_watcher"]), defaults.start_watcher),
      start_importer:
        value_or_default(get_in(toml, ["workers", "start_importer"]), defaults.start_importer),
      mtga_data_dir:
        expand(get_in(toml, ["mtga_logs", "data_dir"])) ||
          defaults.mtga_data_dir
    }
  end

  defp expand(path) when is_binary(path), do: Path.expand(path)
  defp expand(_), do: nil

  defp value_or_default(nil, default), do: default
  defp value_or_default(value, _default), do: value
end
```

- [ ] **Step 4: Run tests**

```bash
mix test test/scry_2/config_test.exs
```
Expected: all tests pass.

- [ ] **Step 5: Run full test suite**

```bash
mix precommit
```
Expected: zero warnings, all tests pass.

- [ ] **Step 6: Commit**

```bash
jj desc -m "feat: add first-run config generation and platform-aware paths"
```

---

## Task 4: Add Windows `Player.log` path to `LocateLogFile`

**Files:**
- Modify: `lib/scry_2/mtga_log_ingestion/locate_log_file.ex`
- Modify: `test/scry_2/mtga_log_ingestion/locate_log_file_test.exs` (find existing test file)

- [ ] **Step 1: Find the existing test file**

```bash
find test -name "locate_log_file*"
```

- [ ] **Step 2: Write failing test for Windows candidate presence**

In the locate_log_file test file, add:

```elixir
describe "default_candidates/0" do
  test "includes a Windows-style AppData path" do
    candidates = LocateLogFile.default_candidates()
    assert Enum.any?(candidates, &String.contains?(&1, "AppData"))
  end

  test "includes a macOS Library path" do
    candidates = LocateLogFile.default_candidates()
    assert Enum.any?(candidates, &String.contains?(&1, "Library/Logs"))
  end
end
```

- [ ] **Step 3: Run to confirm Windows test fails**

```bash
mix test test/scry_2/mtga_log_ingestion/locate_log_file_test.exs
```
Expected: the Windows AppData test fails; macOS test passes.

- [ ] **Step 4: Add Windows path to `default_candidates/0`**

In `lib/scry_2/mtga_log_ingestion/locate_log_file.ex`, add to the list returned by `default_candidates/0`, before the `macOS (native)` entry:

```elixir
      # Windows (native MTGA client)
      Path.join([
        home,
        "AppData",
        "LocalLow",
        "Wizards Of The Coast",
        "MTGA",
        "Player.log"
      ]),
```

- [ ] **Step 5: Run tests**

```bash
mix test test/scry_2/mtga_log_ingestion/locate_log_file_test.exs
```
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
jj desc -m "feat: add Windows native Player.log candidate path"
```

---

## Task 5: Create Windows install/uninstall scripts via release overlay

**Files:**
- Create: `rel/overlays/install.bat`
- Create: `rel/overlays/uninstall.bat`

The `rel/overlays/` directory causes `mix release` to copy these files into `_build/prod/rel/scry_2/` automatically.

- [ ] **Step 1: Create `rel/overlays/` directory and `install.bat`**

Create `rel/overlays/install.bat`:

```batch
@echo off
setlocal enabledelayedexpansion

echo Installing Scry2...

set INSTALL_DIR=%LOCALAPPDATA%\scry_2
set SCRIPT_DIR=%~dp0

REM Remove previous install if present
if exist "%INSTALL_DIR%" (
    echo Stopping previous installation...
    if exist "%INSTALL_DIR%\bin\scry_2.bat" (
        call "%INSTALL_DIR%\bin\scry_2.bat" stop 2>nul
    )
    timeout /t 2 /nobreak >nul
    rmdir /s /q "%INSTALL_DIR%"
)

REM Copy release to AppData\Local\scry_2
echo Copying files to %INSTALL_DIR%...
mkdir "%INSTALL_DIR%"
xcopy /e /i /q /h "%SCRIPT_DIR%." "%INSTALL_DIR%" >nul

REM Register autostart on login
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" ^
    /v "Scry2" ^
    /t REG_SZ ^
    /d "\"%INSTALL_DIR%\bin\scry_2.bat\" start" ^
    /f >nul

REM Start the app
echo Starting Scry2...
start "" /B "%INSTALL_DIR%\bin\scry_2.bat" start

REM Open browser after the app has time to boot
timeout /t 4 /nobreak >nul
start "" http://localhost:4002

echo.
echo Scry2 installed successfully!
echo It will start automatically on each login.
echo Open http://localhost:4002 in your browser to view your stats.
echo.
pause
```

- [ ] **Step 2: Create `rel/overlays/uninstall.bat`**

```batch
@echo off
echo Uninstalling Scry2...

REM Stop the running instance
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
echo Your data and config have been preserved:
echo   Config: %APPDATA%\scry_2\config.toml
echo   Data:   %LOCALAPPDATA%\scry_2\  (removed with install files)
echo.
echo To also remove your data, delete: %APPDATA%\scry_2\
echo.
pause
```

- [ ] **Step 3: Verify overlays are included in a release build**

```bash
MIX_ENV=prod mix release --overwrite
ls _build/prod/rel/scry_2/install.bat
```
Expected: `install.bat` present in the release root.

- [ ] **Step 4: Commit**

```bash
jj desc -m "feat: add Windows install/uninstall scripts via release overlay"
```

---

## Task 6: Create Linux install/uninstall scripts

**Files:**
- Create: `scripts/install`
- Create: `scripts/uninstall`

These are copied into the Linux release archive by the GitHub Actions packaging step.

- [ ] **Step 1: Create `scripts/install`**

```bash
#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$HOME/.local/lib/scry_2"
SERVICE_NAME="scry-2"
SERVICE_FILE="$HOME/.config/systemd/user/${SERVICE_NAME}.service"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing Scry2..."

# Stop existing service if running
if systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    echo "Stopping existing Scry2 service..."
    systemctl --user stop "$SERVICE_NAME"
fi

# Copy release files
echo "Copying files to $INSTALL_DIR..."
rm -rf "$INSTALL_DIR"
mkdir -p "$(dirname "$INSTALL_DIR")"
cp -r "$SCRIPT_DIR/." "$INSTALL_DIR/"

# Write systemd service unit
mkdir -p "$(dirname "$SERVICE_FILE")"
cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Scry2 — MTGA stats tracker
After=network.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/bin/scry_2 start
ExecStop=$INSTALL_DIR/bin/scry_2 stop
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF

# Enable and start
systemctl --user daemon-reload
systemctl --user enable "$SERVICE_NAME"
systemctl --user start "$SERVICE_NAME"

echo "Scry2 is running at http://localhost:4002"

# Open browser if possible
if command -v xdg-open &>/dev/null; then
    sleep 3
    xdg-open "http://localhost:4002" &>/dev/null &
fi

echo ""
echo "Scry2 installed! It will start automatically on login."
echo "Access your stats at: http://localhost:4002"
echo "View logs with: journalctl --user -u scry-2 -f"
```

- [ ] **Step 2: Create `scripts/uninstall`**

```bash
#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="scry-2"
INSTALL_DIR="$HOME/.local/lib/scry_2"
SERVICE_FILE="$HOME/.config/systemd/user/${SERVICE_NAME}.service"

echo "Uninstalling Scry2..."

# Stop and disable service
if systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    systemctl --user stop "$SERVICE_NAME"
fi

if systemctl --user is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
    systemctl --user disable "$SERVICE_NAME"
fi

# Remove service file
rm -f "$SERVICE_FILE"
systemctl --user daemon-reload

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

- [ ] **Step 3: Make scripts executable**

```bash
chmod +x scripts/install scripts/uninstall
```

- [ ] **Step 4: Commit**

```bash
jj desc -m "feat: add Linux install/uninstall scripts"
```

---

## Task 7: Create macOS install/uninstall scripts

**Files:**
- Create: `scripts/install-macos`
- Create: `scripts/uninstall-macos`

- [ ] **Step 1: Create `scripts/install-macos`**

```bash
#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="$HOME/.local/lib/scry_2"
PLIST_LABEL="com.scry_2"
PLIST_FILE="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing Scry2..."

# Unload existing launch agent if present
if launchctl list "$PLIST_LABEL" &>/dev/null; then
    echo "Stopping existing Scry2 service..."
    launchctl unload "$PLIST_FILE" 2>/dev/null || true
fi

# Copy release files
echo "Copying files to $INSTALL_DIR..."
rm -rf "$INSTALL_DIR"
mkdir -p "$(dirname "$INSTALL_DIR")"
cp -r "$SCRIPT_DIR/." "$INSTALL_DIR/"

# Write launchd plist
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
        <string>${INSTALL_DIR}/bin/scry_2</string>
        <string>start</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>/tmp/scry_2.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/scry_2.log</string>
</dict>
</plist>
EOF

# Load and start
launchctl load "$PLIST_FILE"

echo "Scry2 is running at http://localhost:4002"

# Open browser after boot time
sleep 3
open "http://localhost:4002" 2>/dev/null || true

echo ""
echo "Scry2 installed! It will start automatically on login."
echo "Access your stats at: http://localhost:4002"
echo "View logs with: tail -f /tmp/scry_2.log"
```

- [ ] **Step 2: Create `scripts/uninstall-macos`**

```bash
#!/usr/bin/env bash
set -euo pipefail

PLIST_LABEL="com.scry_2"
PLIST_FILE="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
INSTALL_DIR="$HOME/.local/lib/scry_2"

echo "Uninstalling Scry2..."

# Unload launch agent
if launchctl list "$PLIST_LABEL" &>/dev/null; then
    launchctl unload "$PLIST_FILE" 2>/dev/null || true
fi

# Remove plist
rm -f "$PLIST_FILE"

# Remove install directory
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

- [ ] **Step 3: Make scripts executable**

```bash
chmod +x scripts/install-macos scripts/uninstall-macos
```

- [ ] **Step 4: Commit**

```bash
jj desc -m "feat: add macOS install/uninstall scripts via launchd"
```

---

## Task 8: GitHub Actions release workflow

**Files:**
- Create: `.github/workflows/release.yml`

- [ ] **Step 1: Create `.github/workflows/release.yml`**

```yaml
name: Release

on:
  push:
    tags:
      - 'v*'

permissions:
  contents: write

jobs:
  build:
    name: Build (${{ matrix.os }})
    runs-on: ${{ matrix.os }}
    strategy:
      fail-fast: false
      matrix:
        include:
          - os: ubuntu-latest
            platform: linux-x86_64
            ext: tar.gz
          - os: macos-latest
            platform: macos-aarch64
            ext: tar.gz
          - os: windows-latest
            platform: windows-x86_64
            ext: zip

    steps:
      - uses: actions/checkout@v4

      - uses: erlef/setup-beam@v1
        with:
          elixir-version: '1.18'
          otp-version: '27'

      - name: Cache Mix deps and build
        uses: actions/cache@v4
        with:
          path: |
            deps
            _build
          key: ${{ runner.os }}-mix-${{ hashFiles('**/mix.lock') }}
          restore-keys: ${{ runner.os }}-mix-

      - name: Install dependencies
        run: mix deps.get --only prod
        env:
          MIX_ENV: prod

      - name: Deploy assets
        run: mix assets.deploy
        env:
          MIX_ENV: prod

      - name: Build release
        run: mix release
        env:
          MIX_ENV: prod
          MIX_OS_DEPS_COMPILE_PARTITION_COUNT: "8"

      - name: Package release (Linux)
        if: matrix.os == 'ubuntu-latest'
        run: |
          ARCHIVE="scry_2-${{ github.ref_name }}-${{ matrix.platform }}"
          mkdir "$ARCHIVE"
          cp -r _build/prod/rel/scry_2/. "$ARCHIVE/"
          # Remove Windows scripts from Linux archive
          rm -f "$ARCHIVE/install.bat" "$ARCHIVE/uninstall.bat"
          # Add Linux install scripts
          cp scripts/install "$ARCHIVE/install"
          cp scripts/uninstall "$ARCHIVE/uninstall"
          printf "Run ./install to set up Scry2.\nSee https://github.com/${{ github.repository }} for full instructions.\n" > "$ARCHIVE/README.txt"
          tar czf "${ARCHIVE}.tar.gz" "$ARCHIVE"

      - name: Package release (macOS)
        if: matrix.os == 'macos-latest'
        run: |
          ARCHIVE="scry_2-${{ github.ref_name }}-${{ matrix.platform }}"
          mkdir "$ARCHIVE"
          cp -r _build/prod/rel/scry_2/. "$ARCHIVE/"
          rm -f "$ARCHIVE/install.bat" "$ARCHIVE/uninstall.bat"
          cp scripts/install-macos "$ARCHIVE/install"
          cp scripts/uninstall-macos "$ARCHIVE/uninstall"
          printf "Run ./install to set up Scry2.\nSee https://github.com/${{ github.repository }} for full instructions.\n" > "$ARCHIVE/README.txt"
          tar czf "${ARCHIVE}.tar.gz" "$ARCHIVE"

      - name: Package release (Windows)
        if: matrix.os == 'windows-latest'
        shell: pwsh
        run: |
          $ARCHIVE = "scry_2-${{ github.ref_name }}-${{ matrix.platform }}"
          New-Item -ItemType Directory -Name $ARCHIVE
          Copy-Item -Recurse "_build\prod\rel\scry_2\*" "$ARCHIVE\"
          "Run install.bat to set up Scry2.`nSee https://github.com/${{ github.repository }} for full instructions." | Out-File "$ARCHIVE\README.txt" -Encoding UTF8
          Compress-Archive -Path "$ARCHIVE" -DestinationPath "${ARCHIVE}.zip"

      - name: Upload to GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          files: scry_2-${{ github.ref_name }}-${{ matrix.platform }}.${{ matrix.ext }}
          generate_release_notes: true
```

- [ ] **Step 2: Verify workflow YAML is valid**

```bash
cat .github/workflows/release.yml | python3 -c "import sys, yaml; yaml.safe_load(sys.stdin); print('YAML valid')"
```
Expected: `YAML valid`

- [ ] **Step 3: Commit**

```bash
jj desc -m "ci: add GitHub Actions release workflow for Windows, macOS, Linux"
```

---

## Task 9: README and LICENSE

**Files:**
- Create: `README.md`
- Create: `LICENSE`

- [ ] **Step 1: Create `LICENSE`**

```
MIT License

Copyright (c) 2026 Shawn McCool

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 2: Create `README.md`**

```markdown
# Scry2

A self-hosted Magic: The Gathering Arena stats tracker. Scry2 watches your
`Player.log` file, parses match and draft events, and serves a rich analytics
dashboard at `http://localhost:4002`.

Inspired by [17lands.com](https://17lands.com). Built with Elixir/Phoenix.

---

## Requirements

- Magic: The Gathering Arena with **Detailed Logs** enabled
- Windows 10+, macOS 12+, or Linux (x86_64)
- No other software needed — the runtime is bundled

### Enable Detailed Logs in MTGA

In MTGA: **Options → View Account → Detailed Logs (Plugin Support)**

Without this, Scry2 cannot parse your game data.

---

## Install

1. Download the latest release for your platform from the
   [Releases page](../../releases/latest)
2. Extract the archive
3. Run the install script:
   - **Windows:** double-click `install.bat`
   - **macOS / Linux:** `./install` in a terminal

Scry2 will start automatically on each login and is accessible at
`http://localhost:4002`.

---

## Configuration

On first run, Scry2 creates a config file at:
- **Linux/macOS:** `~/.config/scry_2/config.toml`
- **Windows:** `%APPDATA%\scry_2\config.toml`

Most settings (Player.log path, card refresh schedule, etc.) are configurable
through the **Settings** page in the UI — no manual file editing needed.

If Scry2 can't find your `Player.log` automatically, set the path in
**Settings → Log File**.

---

## Uninstall

Run `uninstall` (or `uninstall.bat` on Windows) from the extracted archive.
Your data and config are preserved; delete `~/.local/share/scry_2/` (Linux),
`~/Library/Application Support/scry_2/` (macOS), or `%APPDATA%\scry_2\`
(Windows) to remove everything.

---

## Running from Source

Requires Elixir 1.18+ and Erlang/OTP 27+.

```bash
mix setup          # install deps, create DB, build assets
mix phx.server     # start dev server at http://localhost:4002
mix test           # run tests
```

---

## Card Data Attribution

Card reference data is sourced from [17lands](https://17lands.com) public
datasets, licensed [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).

---

## License

MIT — see [LICENSE](LICENSE).
```

- [ ] **Step 3: Commit**

```bash
jj desc -m "docs: add README and MIT license for public release"
```

---

## Task 10: Pre-release audit

Before pushing the tag that triggers the release pipeline:

- [ ] **Step 1: Scan git history for secrets**

```bash
git log -p --all | grep -iE "(secret_key_base|password|api_key|token)\s*=" | grep -v "\.exs:" | head -20
```
Expected: no real secrets (env var references and examples are fine).

- [ ] **Step 2: Review `defaults/scry_2.toml` for personal values**

Open `defaults/scry_2.toml` and confirm:
- No personal paths (absolute paths pointing to your home dir)
- No real `self_user_id` values committed
- No real API keys

- [ ] **Step 3: Run full test suite and release build**

```bash
mix precommit
MIX_ENV=prod MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix assets.deploy && MIX_ENV=prod mix release --overwrite
```
Expected: zero warnings, all tests pass, release builds cleanly.

- [ ] **Step 4: Final commit and tag**

```bash
jj desc -m "feat: public distribution — cross-platform releases via GitHub Actions"
jj git push
jj git push --tag v0.1.0
```

---

## Verification Checklist

- [ ] GitHub Actions triggers on the pushed tag and produces three artifacts
- [ ] Linux archive contains `install`, `uninstall`, no `.bat` files
- [ ] macOS archive contains `install` (launchd version), `uninstall`, no `.bat` files
- [ ] Windows archive contains `install.bat`, `uninstall.bat`, no shell scripts (or if present, harmless)
- [ ] First boot generates `config.toml` with `secret_key_base`, `[database]`, and `[cache]`
- [ ] Second boot reads the same `config.toml` (stable key)
- [ ] App binds to `127.0.0.1:4002` (not 0.0.0.0)
- [ ] `LocateLogFile.default_candidates()` includes a Windows `AppData` path
- [ ] Settings UI shows the player log path and allows editing it
