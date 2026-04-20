---
status: accepted
date: 2026-04-20
---
# 033. Elixir-native self-update, tray is a thin launcher

## Status

Accepted

## Context and Problem Statement

Scry2 originally owned its self-update pipeline entirely in the Go tray
binary (`tray/updater/`). The tray hourly-polled GitHub Releases,
downloaded archives, extracted them, and spawned the platform installer
script. The Elixir backend had zero knowledge of versions, updates, or
releases.

This split created three concrete problems:

1. **Two runtimes for one concern.** Update logic was written twice in
   spirit — once in Go for orchestration, once in the install scripts for
   file placement. Changes to release packaging (e.g. adding a new file
   that needed post-install wiring) had to be coordinated across Go +
   bash + batch + WiX.

2. **No user-visible update state.** The tray menu had a single "Check
   for Updates" item that either silently succeeded, silently failed, or
   showed a terse label. There was no place for "last checked 47 minutes
   ago", "download 34% complete", or "verification failed — retrying."
   The user couldn't opt in or out, couldn't see what version was latest,
   and couldn't diagnose failures.

3. **Security posture scattered across Go.** Tag validation, URL
   construction, checksum verification, and archive entry validation all
   lived in Go code that the Elixir-focused maintainer rarely touched.
   Reviews were harder; audit trails thinner.

The maturing `media-centarr` sibling project had already adopted a
purely-Elixir update subsystem with an Oban cron, GenServer state
machine, durable storage, PubSub progress broadcasts, and a LiveView UI
surface. That architecture was production-proven and obviously cleaner.

The question was: move the scry_2 update pipeline into Elixir, or keep
the Go tray as the owner?

## Decision Drivers

- **Single authoritative codepath.** Prefer one runtime owning the
  end-to-end concern; the other (tray) reduces to a thin launcher.
- **User-visible state and observability.** Updates should surface in the
  same LiveView UI the user already uses for diagnostics, with live
  progress, failure reasons, and an audit trail of past checks.
- **Security rigor.** Tag regex, URL template construction, checksum
  verification, and archive entry validation should live where the rest
  of the app's defense-in-depth lives — in reviewable Elixir code
  alongside tests.
- **Platform matrix reality.** Scry2 ships Linux, macOS, and Windows
  (zip + MSI). The solution must work on all four without forking the
  codepath.
- **`media-centarr` as exemplar.** Per memory/reference, media-centarr's
  backend is the scry_2 pattern exemplar. Its self-update modules are a
  direct template.

## Considered Options

### Option A — Keep update logic in the Go tray (status quo)

Continue owning checker, downloader, extractor, and installer in
`tray/updater/`. Elixir remains oblivious. Improve by adding a version
endpoint and richer CLI output.

**Pros:**
- No migration cost.
- Tray already detaches cleanly from the BEAM at apply time.

**Cons:**
- Perpetuates the dual-runtime split.
- No user-visible update UI without either exposing a local HTTP API
  from tray → Elixir or duplicating rendering in Go.
- Two testing stories (Go test + Elixir test) for one concern.

### Option B — Elixir-native updater, tray becomes a thin launcher *(chosen)*

Port the media-centarr subsystem to scry_2 as `Scry2.SelfUpdate`. Tray
loses its `updater/` package entirely. An on-disk `apply.lock` file
coordinates the tray watchdog with in-flight updates — the tray reads
the lock before every restart attempt and skips the restart while a
fresh lock is present.

**Pros:**
- Single authoritative pipeline across all platforms.
- Updates surface in the existing Settings LiveView with live progress,
  last-checked timestamps, failure reasons.
- Security code (tag regex, URL template, `secure_compare`, archive
  validation) lives in reviewable Elixir alongside unit tests.
- Tray shrinks substantially (~17 deleted files, ~15 LoC added for the
  apply-lock check).
- No new IPC boundary — `apply.lock` is a file both processes trust.

**Cons:**
- Larger initial change (new subsystem + CI additions + tray surgery).
- The apply handoff needs platform-aware spawn logic in Elixir (already
  small — `setsid` / `nohup` / `cmd /c start` dispatched on `:os.type/0`).
- Windows MSI handoff requires the BEAM to `System.stop/1` cleanly so
  the installer can replace `erl.exe`/`beam.smp`.

### Option C — Hybrid: Elixir plans, tray executes

Elixir owns check/download/stage/broadcast. When ready to apply, it HTTP-
calls the tray (`POST /apply-update?staged_path=...`) and the tray does
the shutdown-and-spawn.

**Pros:**
- Keeps the tray's platform-specific launch knowledge in Go where it
  already lives.

**Cons:**
- Adds a new IPC boundary (localhost HTTP) that didn't exist.
- Two-part architecture stays — prevents deleting `tray/updater/`.
- Tray still has to ship platform-specific install logic; not meaningfully
  simpler than Option B.

## Decision Outcome

Chosen option: **B — Elixir-native updater with apply-lock coordination**,
because it collapses the dual-runtime split into one authoritative
pipeline, gives us a proper LiveView surface for update state, and
concentrates security-critical code in one reviewable location.

Approach B2 specifically (over B1): **replace-in-place install layout**,
not atomic `releases/<version>/` + `current/` symlinks. Matches the
existing scry_2 installer model; smaller diff; Windows MSI already gives
its own atomicity via component tracking. The atomic-symlink path is
available as a future refinement if replace-in-place proves inadequate.

### Architecture

New subsystem `Scry2.SelfUpdate` under `lib/scry_2/self_update/`:

| Module | Responsibility |
|---|---|
| `Scry2.SelfUpdate` | Public facade, boot hook, `enabled?/0` compile gate |
| `UpdateChecker` | Tag regex validation, URL template, classification, `:persistent_term` 1h cache |
| `CheckerJob` (Oban) | Hourly cron worker, 55-min unique window, manual "Check now" bypass |
| `Storage` | Durable `last_check_at` + `latest_known` via `Settings.Entry` |
| `Updater` (GenServer) | State machine `idle → preparing → downloading → extracting → handing_off → done/failed`, serialized applies |
| `Downloader` | Archive + `SHA256SUMS` fetch, `Plug.Crypto.secure_compare/2` verification |
| `Stager` | Pre-extraction per-entry validation (rejects `..`, symlinks, absolute paths, oversize) |
| `Handoff` | Platform-dispatched detached installer spawn |
| `ApplyLock` | `$DATA_DIR/apply.lock` lifecycle + stale detection |

UI: `Scry2Web.SettingsLive.UpdatesCard` + `UpdatesHelpers` (extracted per
ADR-013). Subscribes to PubSub topics `updates:status` (check results) and
`updates:progress` (apply phase).

Tray change: `tray/apply_lock.go` reads the lock file; `tray/backend.go`
watchdog consults it before every restart attempt. Lock is considered
active if file exists, parses as JSON, and `started_at` is within 15
minutes. Stale / malformed / missing = inactive (watchdog restarts
normally).

### Coordination contract

The `apply.lock` file is the only new protocol between Elixir and Go.
JSON, single line, at `$DATA_DIR/apply.lock`:

```json
{"pid":12345,"version":"0.15.0","phase":"downloading","started_at":"2026-04-20T18:03:11Z"}
```

Lifecycle:

1. `Updater` writes the lock before transitioning past `preparing`.
2. Tray watchdog reads the lock on each restart attempt; if fresh, skips.
3. `Updater` updates the `phase` field as state advances (informational).
4. Installer script (`install-linux` / `install-macos` / `install.bat`)
   removes the lock as its second-to-last step, right before relaunching
   `scry2-tray`.
5. `Scry2.SelfUpdate.boot!/0` clears stale locks (>15 min or
   unparseable) at BEAM startup to recover from crashed applies.

### CI

`release.yml` generates per-platform `scry_2-<tag>-<platform>-x86_64-SHA256SUMS`
files alongside each archive and uploads them to the GitHub release.
`UpdateChecker.sha256sums_name/2` computes the expected filename at
runtime based on `:os.type/0`.

### Security posture

- **Strict tag regex.** `~r/^v\d+\.\d+\.\d+(-[A-Za-z0-9.]+)?$/` at every
  interpolation boundary. Rejects shell-injection attempts, path
  traversal, URL spoofing.
- **URL construction, never extraction.** Download URLs built from a
  fixed template + validated tag. A compromised GitHub API cannot
  redirect to attacker-controlled hosts.
- **Checksum from file, not API.** `SHA256SUMS` is a separate file;
  `Plug.Crypto.secure_compare/2` is constant-time.
- **Pre-extraction validation.** Every tar/zip entry is inspected before
  any filesystem write. `..`, absolute paths, symlinks, oversize all
  reject with zero bytes written.
- **Detached spawn with minimal env.** `env -i` plus a whitelist
  (`HOME`, `XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS`, etc.); no
  secrets leak to the installer child.

## Consequences

**Good:**

- Single codepath owns the update concern; `tray/updater/` is gone
  (17 files deleted).
- Users see update state in the same LiveView they already use for
  diagnostics; no new UI surface.
- Security code is reviewable Elixir with unit tests (62 tests in
  `test/scry_2/self_update/`).
- The tray binary lost its build-time variants — one `scry2-tray.exe` is
  used by both the zip and MSI install paths on Windows. Simpler CI,
  fewer `-X` ldflags, no `InstallerType`/`CurrentVersion` to maintain.
- Per-platform SHA256SUMS in CI is a net security improvement regardless
  of updater ownership.
- Replay / recovery: `boot!/0` clears stale locks so a crashed apply
  doesn't permanently wedge the watchdog.

**Bad:**

- First-release risk: the end-to-end apply flow exercises Elixir →
  installer handoff → BEAM exit → installer replaces files → tray
  relaunches. No end-to-end test covers this; the first production
  release is the integration test. Mitigated by unit tests for every
  sub-stage and by the apply-lock recovery path.
- Windows MSI apply depends on `Scry2Setup-*.exe /quiet /norestart`
  behaving cleanly when invoked detached from the current BEAM process.
  Also first-release territory.
- Tray watchdog now has a file-system dependency in its hot path (every
  10s). Acceptable cost: `os.ReadFile` on a ~128-byte JSON file.

**Neutral:**

- `Mix.env() == :prod` compile-time gate means dev/test are inert. A
  developer who wants to exercise the update UI manually must populate
  `UpdateChecker.put_cache/1` in an IEx session (documented in
  DEVELOPMENT.md).

## Related Decisions

- ADR-009: GenServer API encapsulation — Updater tests only use public
  API (`apply_pending/1`, `status/1`) and PubSub observations, no
  `:sys.replace_state` or internal peeks.
- ADR-013: LiveView logic extraction — Updates card logic lives in
  `UpdatesHelpers` with its own unit test; the LiveView is thin wiring.
- ADR-019: Domain-purpose naming — `Scry2.SelfUpdate` is an infrastructure
  subsystem, not a domain context, and names modules by what they do
  (`UpdateChecker`, `Downloader`, `Stager`, `Handoff`) rather than by
  pattern (no `Worker`, no `Translator`, no `Manager`).

## References

- Design spec: `specs/2026-04-20-elixir-self-update-design.md`
- Implementation plan: `specs/2026-04-20-elixir-self-update-plan.md`
- Reference implementation: `~/src/media-centarr/media-centarr/lib/media_centarr/self_update/`
