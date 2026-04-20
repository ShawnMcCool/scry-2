# Elixir-Native Self-Update for Scry2

**Status:** Design — pending implementation plan
**Date:** 2026-04-20
**Author:** Shawn (via Claude)

## Goal

Move self-update responsibility out of the Go tray binary and into the Elixir
application, matching the mature pattern used in `media-centarr`. The tray
becomes a pure desktop launcher (backend supervision, tray icon, autostart,
first-run browser open); all update checking, downloading, verification, and
apply orchestration lives in Elixir and is observable via the Settings
LiveView.

## Non-Goals

- Atomic symlink install layout (`releases/<version>/` + `current/` symlink) —
  deliberately deferred. Replace-in-place everywhere, matching today's install
  scripts. Simplicity wins.
- Automatic rollback on failed apply. A failure leaves the old installation
  running; user retries via the Settings UI.
- Removing the tray binary. Tray keeps launching, supervising, and autostarting
  the backend on all three platforms. Only the `tray/updater/` subtree is
  deleted.
- Changing release artifact names or install paths.

## Architecture

### New bounded subsystem: `Scry2.SelfUpdate`

Cross-cutting infrastructure — not a domain context. All modules live under
`lib/scry_2/self_update/` and share one public facade at
`lib/scry_2/self_update.ex`.

| Module | Responsibility |
|---|---|
| `Scry2.SelfUpdate` | Public facade. Boot hook, subscribe helpers, `check_now/0`, `apply_pending/0`, `current_version/0`. |
| `Scry2.SelfUpdate.UpdateChecker` | GitHub Releases API fetch; tag validation; `:persistent_term` cache (1h TTL); rate-limit detection. Pure — no DB. |
| `Scry2.SelfUpdate.CheckerJob` | Oban worker. Hourly cron; 55-min `unique` dedup window. Calls `UpdateChecker` + `Storage`. |
| `Scry2.SelfUpdate.Storage` | Reads/writes `updates.last_check_at` and `updates.latest_known` via existing `Settings.Entry`. Hydrates `:persistent_term` at boot. |
| `Scry2.SelfUpdate.Updater` | GenServer state machine: `idle → preparing → downloading → extracting → handing_off → done/failed`. Serializes applies. |
| `Scry2.SelfUpdate.Downloader` | Fetch archive + `SHA256SUMS`, verify with `Plug.Crypto.secure_compare/2`, emit progress. |
| `Scry2.SelfUpdate.Stager` | Per-platform unpack with strict validation (reject `..`, symlinks, absolute paths, oversize). `tar` on Linux/macOS via `:erl_tar`; `zip`/`msi` on Windows via `:zip` (msi is copied, not extracted). |
| `Scry2.SelfUpdate.Handoff` | Platform-dispatched detached spawn of the installer. Writes the apply lock before spawning. |
| `Scry2.SelfUpdate.ApplyLock` | Owns the on-disk lock file (`apply.lock`) the tray's watchdog reads to back off during an apply. |

### Version source of truth

`mix.exs` `version: "X.Y.Z"` → compiled into the app → read at runtime via
`Application.spec(:scry_2, :vsn) |> to_string()`. The `SelfUpdate` facade
exposes `current_version/0` for LiveView and the tray.

### Tray coordination (the new contract)

The tray's job during an apply is: **don't restart the backend while files are
being replaced.** Today the tray watchdog restarts the backend every 10s on
crash. We add a single coordination primitive:

**Apply lock file.** Path resolved via the app's existing data-dir helper, with
`apply.lock` appended. The tray's Go code derives the same path from the same
platform rules it already uses to locate `scry_2.db`. Neither side hardcodes
paths; both agree via platform convention.

Contents (JSON, single line):

```json
{"pid":12345,"version":"0.15.0","phase":"downloading","started_at":"2026-04-20T18:03:11Z"}
```

**Lifecycle:**

1. Before `Updater` transitions past `preparing`, `ApplyLock.acquire/1` writes the file with the Elixir BEAM's OS pid.
2. Tray's watchdog (`tray/backend.go`) is modified to read the lock before every restart attempt; if present and less than 15 minutes old, skip the restart.
3. `Handoff` spawns the installer detached, marks `phase: "handing_off"` in the lock, then stops the BEAM. The installer script deletes the lock as its last step (before relaunching the tray on Unix, or exiting on Windows where the MSI/bat itself relaunches).
4. Stale locks (> 15 min, or pid no longer alive on Unix) are cleared at BEAM boot by `SelfUpdate.boot!/0`.

The watchdog check is the only change in Go. No HTTP endpoint, no IPC channel
— a file the installer script already writes elsewhere is an ambient
coordination medium both processes trust.

### Per-platform Handoff

| Platform | Archive | Handoff spawn | Who restarts backend |
|---|---|---|---|
| Linux | `scry_2-vX.Y.Z-linux-x86_64.tar.gz` | `setsid sh -c '<staged>/install-linux >> handoff.log 2>&1'` with `env -i HOME=... PATH=...` | `install-linux` re-launches `scry2-tray`; tray starts backend |
| macOS | `scry_2-vX.Y.Z-macos-x86_64.tar.gz` | `/bin/sh -c 'nohup <staged>/install-macos >> handoff.log 2>&1 &'` | `install-macos` re-launches via `launchctl` |
| Windows zip | `scry_2-vX.Y.Z-windows-x86_64.zip` | `cmd.exe /c start "" /B "<staged>\install.bat"` (detached) | `install.bat` re-launches `scry2-tray.exe` |
| Windows MSI | `Scry2Setup-X.Y.Z.exe` (bootstrapper) | `cmd.exe /c start "" /B "<staged>\Scry2Setup-X.Y.Z.exe" /quiet /norestart` | Bootstrapper's `util:CloseApplication` kills tray+BEAM; `LaunchTray` custom action starts tray post-install |

The `Handoff` module is a single `case :os.type()` dispatcher. Total ~80 LoC
including the spawn-and-exit sequencing.

### CI additions

`release.yml` gains one step per platform: generate `SHA256SUMS` alongside the
archive. Format: `<hex>  <filename>` per line, matching `sha256sum`'s output.
The file is uploaded to the GitHub Release as a standalone asset. `Downloader`
fetches it and parses by archive filename.

Windows note: PowerShell `Get-FileHash ... -Algorithm SHA256` produces
capitalized hex; normalize to lowercase in the release workflow.

## Data Flow

### Check path (background, every hour)

```
Oban cron fires CheckerJob
  → UpdateChecker.latest_release()
    → Req.get(GitHub API, 5s timeout)
    → parse + validate tag regex
    → build classification (:update_available | :up_to_date | :ahead_of_release)
  → Storage.record_check_result(result)
    → write Settings.Entry rows
    → update :persistent_term cache
  → Phoenix.PubSub.broadcast("updates:status", {:check_complete, outcome})
```

Any LiveView subscribed to `updates:status` sees the new cached release. No
notifications, no toasts — surfaced only in the Settings page.

### Apply path (user-initiated from Settings LiveView)

```
user clicks "Apply Update"
  → SelfUpdate.apply_pending()
  → Updater GenServer: idle → preparing
    → validate cached release; no downgrade
    → ApplyLock.acquire(version)
  → spawn Task under Scry2.TaskSupervisor:
      Updater → downloading
        Downloader.run(url, sha256sums_url, staging_dir)
          → stream archive to tmp
          → fetch SHA256SUMS, lookup + secure_compare
          → emit progress on 1% boundaries (PubSub "updates:progress")
      Updater → extracting
        Stager.extract(archive, staging_dir)
          → :erl_tar / :zip with per-entry validation
          → assert required files present
      Updater → handing_off
        Handoff.spawn_detached(staged_root)
          → write installer handoff.log redirect
          → spawn installer per platform
        ApplyLock.mark_handing_off()
      System.stop(0)   # BEAM exits cleanly; installer replaces files;
                       # installer removes ApplyLock and relaunches tray.
```

On any failure before `handing_off`: `Updater` transitions to `failed`, clears
the lock, broadcasts the error. The user sees the failure phase + reason in
Settings and can retry.

## Settings LiveView Surface

Add a new card to `settings_live` titled **"Updates"**. Sections:

1. **Current version** — `Scry2.SelfUpdate.current_version()` + build timestamp.
2. **Latest known release** — from `:persistent_term` cache. Shows version, published_at, link to GitHub release notes. "Check now" button next to it (enqueues an Oban job, bypasses the 1h dedup with `replace: [:scheduled_at]`).
3. **Apply pending update** — only rendered when classification is `:update_available`. Button fires `apply_pending/0`, page subscribes to `updates:progress` and renders a phase indicator (preparing / downloading XX% / extracting / handing off).
4. **Failure state** — if last apply failed, show the error message and a retry button.

LiveView logic is extracted into `Scry2.SelfUpdate.LiveHelpers` per [ADR-013]
— the LiveView module itself just wires `mount` + `handle_event` + `handle_info`.

## Security Posture

Lifted verbatim from media-centarr — these are non-negotiable:

- **Strict tag regex.** `~r/^v\d+\.\d+\.\d+(-[A-Za-z0-9.]+)?$/`. Reject anything else before interpolation.
- **URL template, never API response.** Build `https://github.com/shawnmccool/scry_2/releases/download/<tag>/<archive>` from the validated tag. Ignore `browser_download_url` from the API.
- **Checksum via SHA256SUMS file, not API field.** `Plug.Crypto.secure_compare/2`.
- **Archive entry pre-validation.** Reject `..`, absolute paths, symlinks, device files, oversize (cap at 500 MB cumulative).
- **Detached spawn.** `setsid` / `nohup` / `start /B`; redirect stdio; minimal env on Unix.
- **Staging directory** created with `0o700` on Unix. On Windows, default tempdir ACL is fine (user-owned).
- **No TLS opt-out flag.** Req's default verification is always on.

## Configuration

All auto, no user-facing config today. Implicit rules:

- `Scry2.SelfUpdate.enabled?()` is driven by a compile-time constant
  (`@enabled Mix.env() == :prod`) rather than runtime `Mix.env/0`, since Mix
  is not available in releases. In dev/test the Oban job no-ops; the Settings
  card shows "Updates disabled in development."
- Check cadence: hourly cron. Cache TTL: 60 minutes in `:persistent_term`.
  Oban `unique: [period: :infinity, states: [:available, :scheduled, :executing]]`
  on the cron job prevents scheduled duplicates. The manual "Check now" button
  enqueues a one-off job with `replace: [args: [:manual]]` so it bypasses the
  scheduled-job uniqueness and runs immediately.

A future `updates.auto_check` TOML key can be added without breaking anything,
but it is explicitly out of scope for this spec.

## Tray Changes (Go)

Deleted:

```
tray/updater/downloader.go
tray/updater/downloader_test.go
tray/updater/extractor.go
tray/updater/extractor_test.go
tray/updater/github.go
tray/updater/github_test.go
tray/updater/installer_unix.go
tray/updater/installer_unix_test.go
tray/updater/installer_windows.go
tray/updater/installer_windows_test.go
tray/updater/updater.go
tray/updater/updater_test.go
```

Modified:

- `tray/main.go` — remove `updater.Start(...)` call, remove "Check for Updates" menu item (replaced by "Open Settings" deep-link to `http://localhost:6015/settings#updates`).
- `tray/backend.go` — watchdog reads the apply lock before restart. ~15 LoC.
- Build flags — `-X 'scry2/tray/updater.CurrentVersion=...'` and `-X 'scry2/tray/updater.InstallerType=msi'` are removed from `scripts/release` and `release.yml`. Tray no longer needs a version or installer-type identity.

`tray-ci.yml` gets the updater tests removed from its matrix.

## Testing Strategy

Per project policy, test-first.

**Pure function tests (`async: true`, no DB):**

- `UpdateChecker` — tag regex, classification (`:update_available` / `:up_to_date` / `:ahead_of_release` / `:invalid`), URL construction, rate-limit header parsing. Inject `Req` via module attribute for stubbing.
- `Stager` — per-entry validation rules, one test per rejected case (`..`, symlinks, absolute, oversize), plus happy path with a real tar fixture.
- `Downloader` — checksum mismatch rejection, `secure_compare` path; use `bypass` or `Req.Test` for HTTP.

**Resource tests (`DataCase`):**

- `Storage` — round-trip `record_check_result/1`, hydration of `:persistent_term` cache at boot, concurrency-safe updates.

**GenServer tests (public API only, per [ADR-009]):**

- `Updater` — state machine transitions driven by stubbed `Downloader` / `Stager` / `Handoff` injected at start. Assert PubSub broadcasts via `Phoenix.PubSub.subscribe` in the test.

**LiveView integration:**

- Settings page — mount with seeded cache, click "Check now" (assert Oban job enqueued), simulate apply broadcasts via `PubSub.broadcast` and assert phase rendering.

**Explicitly not tested:**

- The actual `Handoff.spawn_detached/1` pipeline end-to-end on real archives.
  Handoff's unit is tested by asserting the exact argv/env it would pass to
  `System.cmd` with a stubbed spawner. The `windows-install-test.yml`
  workflow is the integration check on a real runner.
- The installer scripts themselves (already tested in
  `windows-install-test.yml` and ad-hoc on Linux/macOS).

## Migration / Rollout

One atomic change, not staged:

1. Add `Scry2.SelfUpdate` subsystem (feature-complete with tests).
2. Add `SHA256SUMS` generation to `release.yml`.
3. Teach tray watchdog to read the apply lock.
4. Delete `tray/updater/`.
5. Remove updater build flags from scripts.
6. Wire Settings LiveView card.
7. Ship a release. First successful self-update in the wild is the integration test.

No flag-gating, no dual-path period. Approach B per the brainstorm, atomic PR.

## Open Questions

None blocking — everything above is specified. One minor detail surfaces in
implementation: Windows zip-install currently has no concept of "who relaunches
the tray after the bat file runs." `install.bat` already does `start "" /B
"%INSTALL_DIR%\scry2-tray.exe"` at the end, so this is a non-issue — noted here
so the implementer doesn't re-ask.

## References

- `/home/shawn/src/media-centarr/media-centarr/lib/media_centarr/self_update/` — reference implementation
- [ADR-009] GenServer API encapsulation — `decisions/architecture/2026-04-05-009-genserver-api-encapsulation.md`
- [ADR-013] LiveView logic extraction — `decisions/architecture/2026-04-05-013-liveview-logic-extraction.md`
- Project testing policy — `CLAUDE.md` §Testing Strategy
