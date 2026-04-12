# Platform Compatibility Audit

**Date:** 2026-04-12
**Scope:** Elixir runtime, Go tray binary, install scripts, CI/CD, config generation
**Platforms:** Linux, macOS, Windows

## Severity Scale

| Level | Meaning |
|-------|---------|
| **P0** | Broken on platform — users cannot use Scry2 |
| **P1** | Degraded or confusing UX — real user-facing gap |
| **P2** | Suboptimal but functional — minor risk or inefficiency |
| **P3** | Cosmetic or documentation only |

---

## Category A: Config & Path Generation (Elixir)

### A-1: Bootstrap config TOML literal strings (P2 — Verified Correct)

**Evidence:** `lib/scry_2/config.ex:71-74`

The recent fix (commit 2f56403) correctly uses TOML literal strings (single quotes) for
`database.path` and `cache.dir` in the bootstrap config. Single-quoted TOML strings do not
interpret backslashes, so Windows paths like `C:\Users\...` are preserved correctly.

**Status:** No action needed. The fix is correct. A regression test is recommended (see F-3).

### A-2: defaults/scry_2.toml shows Linux paths only (P1)

**Evidence:** `defaults/scry_2.toml:12` — `path = "~/.local/share/scry_2/scry_2.db"`

The defaults template (documentation-only, never loaded at runtime) shows only Linux paths.
Windows users reading it for guidance will see alien paths like `~/.local/share/` which don't
apply to their platform.

**Recommendation:** Add comments showing Windows and macOS equivalent paths alongside each
Linux example. Effort: S.

### A-3: Path.expand("~") divergence on Windows (P2)

**Evidence:** `lib/scry_2/platform.ex:29,53`

`Platform.config_path/0` and `data_dir/0` correctly use `System.get_env("APPDATA")` with
`System.user_home!()` as fallback on Windows. If `APPDATA` is unset (extremely rare on
Windows), the fallback to `user_home!()` returns `USERPROFILE`, which may differ from
`APPDATA` if profiles are redirected (enterprise environments).

**Status:** Acceptable risk. The fallback is reasonable and the scenario is rare. Document
in the platform skill.

---

## Category B: MTGA File Discovery (Elixir)

### B-1: Windows MTGA Raw dir candidates too narrow (P1)

**Evidence:** `lib/scry_2/platform.ex:124-135`

`mtga_raw_dir_candidates/0` only returns one path for Windows:
`C:\Program Files\Wizards of the Coast\MTGA\MTGA_Data\Downloads\Raw`

This is the standalone installer path. Users who installed MTGA via **Steam** have it in
`steamapps\common\MTGA\...` instead. The Xbox/Microsoft Store installs to a different
location under `%LOCALAPPDATA%\Packages\`.

**Recommendation:** Add Steam path on Windows using `%PROGRAMFILES(X86)%` env var for
the Steam root. Keep existing path as first candidate. Effort: M.

### B-2: Log candidates not filtered by OS (P2)

**Evidence:** `lib/scry_2/platform.ex:73-115`

`mtga_log_candidates/0` returns all 6 candidates unconditionally — including 4 Linux
Proton/Lutris/Bottles paths when running on Windows. The caller filters with `File.regular?/1`
so this is not a bug, but it adds 4 unnecessary filesystem probes on every path resolution.

**Recommendation:** Consider filtering by `:os.type()` like `mtga_raw_dir_candidates/0`
already does. Low priority — the probes are cheap. Effort: S.

### B-3: No macOS MTGA Raw dir candidate (P3)

**Evidence:** `lib/scry_2/platform.ex:138-151`

The `_ ->` branch (non-Windows) only lists Linux Steam paths for Raw card data. MTGA does
not run natively on macOS (only via Wine/CrossOver), so this is not currently a gap.

**Status:** Not applicable. Document as intentional. Effort: S (docs only).

---

## Category C: Log Rotation & File Identity (Elixir)

### C-1: Inode handling verified correct (P2 — No Action)

**Evidence:** `lib/scry_2/mtga_log_ingestion/read_new_bytes.ex:32-34`

`ReadNewBytes.read_since/2` uses `File.stat/1` which returns `inode`. ADR-032 documents
that Wine/NTFS may return `inode: 0`. The inode value is passed through in the return struct
but is **not used for rotation detection** — size comparison (`size < offset`) is the actual
mechanism. The epoch counter in the Watcher is the identity mechanism.

**Status:** Design is already correct. No action needed.

### C-2: Windows file locking undocumented (P2)

**Evidence:** `lib/scry_2/mtga_log_ingestion/read_new_bytes.ex:60`

MTGA holds `Player.log` open while writing. On Windows, file locking is mandatory by default
(unlike Unix advisory locks). `File.open/2` with `:read` should work because MTGA opens
with share-read, but this is untested on Windows.

**Recommendation:** Document Windows file locking behavior in the platform skill. If users
report read failures on Windows, the fix is to use `:delayed_write` or retry with backoff.
Effort: S (docs).

---

## Category D: Go Tray Binary

### D-1: Go/Elixir path sync enforced by comments only (P2)

**Evidence:** `tray/data_dir_windows.go`, `tray/data_dir_linux.go`, `tray/data_dir_darwin.go`

Each Go `DataDir()` function has a "Must stay in sync with Scry2.Platform" comment. There
is no automated verification that Go and Elixir paths match.

**Recommendation:** Add a CI check or integration test that compares Go and Elixir data
directory output for each platform. Effort: M.

### D-2: Browser URL with special chars (P3 — No Action)

**Evidence:** `tray/browser_windows.go`

`cmd /c start` treats URLs with `&` as multiple arguments. The hardcoded
`http://localhost:6015` has no special chars.

**Status:** Safe. No action unless URL gains query parameters.

### D-3: Windows registry value quoting correct (P2 — Verified)

**Evidence:** `tray/autostart_windows.go`

Registry value wraps exe path in quotes, handling paths with spaces correctly.

**Status:** Correct. No action needed.

### D-4: Intel Mac auto-update not supported (P1)

**Evidence:** `tray/updater/platform.go:29`, `.github/workflows/release.yml:59`

The updater supports `darwin/amd64` in `archiveSuffix`, but the CI release matrix only
builds on `macos-latest` (ARM/aarch64). Intel Mac users get an "unsupported platform"
error when checking for updates.

**Recommendation:** Either add `macos-13` runner for x86_64 builds, or remove `darwin/amd64`
from the updater and document Apple Silicon as the only supported macOS architecture.
Effort: M.

### D-5: Zip extraction ignores Unix permissions (P2 — No Action)

**Evidence:** `tray/updater/extractor.go`

`extractZip` uses `os.Create` which doesn't preserve Unix execute permissions. This is
correct behavior — Windows uses `.bat`/`.exe` extensions, not permission bits. The tar.gz
extractor preserves permissions for Unix platforms.

**Status:** Correct by design. No action needed.

---

## Category E: Install Scripts & Release

### E-1: scripts/release is Unix-only (P2)

**Evidence:** `scripts/release:37-39`

The case statement has no Windows case — the fallback exits with "unsupported platform."
Windows builds happen exclusively in CI.

**Recommendation:** Change error message to "Windows builds are CI-only. See
.github/workflows/release.yml". Effort: S.

### E-2: install.bat uses deprecated xcopy (P3)

**Evidence:** `rel/overlays/install.bat:24`

Microsoft considers `xcopy` deprecated in favor of `robocopy`. Functionally identical
for this use case and works on all supported Windows versions.

**Status:** No change needed.

### E-3: install.bat has no pre-flight check (P1)

**Evidence:** `rel/overlays/install.bat`

After copying files, the installer starts the tray without verifying the ERTS runtime
is functional. If `vcredist` is missing or the package is corrupt, the user gets an
opaque error.

**Recommendation:** Add a pre-flight check after copy:
`"%INSTALL_DIR%\bin\scry_2.bat" eval "IO.puts(:ok)"` with error handling and a
user-friendly message if it fails. Effort: S.

### E-4: Firewall note is advisory only (P2)

**Evidence:** `rel/overlays/install.bat:44-47`

The installer warns about epmd/erlang firewall rules but doesn't automate them.
Automating with `netsh advfirewall` would require admin elevation.

**Recommendation:** Improve messaging to explain what happens if the user declines
(Scry2 still works for local access — the firewall rules are only needed for distributed
Erlang, which Scry2 doesn't use in production). Effort: S.

### E-5: Asymmetric install script locations (P3)

**Evidence:** Linux/macOS use `scripts/install-{platform}`, Windows uses `rel/overlays/install.bat`

The release workflow correctly handles this (copies the right scripts per platform into
the archive). Not a bug but confusing for contributors.

**Recommendation:** Document in a comment in `scripts/release`. Effort: S.

---

## Category F: CI/CD

### F-1: No cross-platform Elixir test coverage (P1)

**Evidence:** `.github/workflows/ci.yml:9` — `runs-on: ubuntu-latest` only

Platform-specific code in `Platform.ex` (the `{:win32, _}` and `{:unix, :darwin}` branches)
is never tested. Bugs like the TOML backslash issue (fixed in 2f56403) can only be caught
manually.

**Recommendation:** Two approaches (choose one or both):
1. **Unit tests with extractable branches** — refactor `Platform.ex` to accept OS tuple
   as parameter, test all branches on Ubuntu. Cheap and fast.
2. **Cross-platform CI runners** — add minimal test jobs on `windows-latest` and
   `macos-latest`. Expensive (runner minutes) but tests real platform behavior.

Effort: M (option 1), L (option 2).

### F-2: Go tray CI has good platform coverage (P2 — Positive)

**Evidence:** `.github/workflows/tray-ci.yml`

Go tests run on all 3 platforms via matrix. The Go side has better platform CI coverage
than the Elixir side.

**Status:** Good. No action needed.

### F-3: No TOML backslash regression test (P1)

**Evidence:** `test/scry_2/config_test.exs`

The bootstrap config test verifies content is generated and loadable, but does not verify
that paths containing backslashes (Windows-style) survive TOML round-trip. The fix in
commit 2f56403 cannot be regression-tested.

**Recommendation:** Add a test that generates bootstrap config with a Windows-style path
containing backslashes, verifies TOML literal strings are used, and parses it back to
confirm the path is intact. This can run on any platform. Effort: S.

---

## Priority Summary

| Severity | Count | Findings |
|----------|-------|----------|
| **P0** | 0 | — |
| **P1** | 5 | A-2, B-1, D-4, E-3, F-1/F-3 |
| **P2** | 9 | A-1, A-3, B-2, C-1, C-2, D-1, D-3, D-5, E-1, E-4, F-2 |
| **P3** | 4 | B-3, D-2, E-2, E-5 |

## Recommended Action Items (by impact)

1. **F-3: TOML backslash regression test** — cheap insurance, prevents re-introducing the bootstrap bug
2. **F-1: Platform.ex branch coverage** — extract testable functions, test all OS branches on any runner
3. **B-1: Expand Windows MTGA Raw dir candidates** — real gap for Steam/Xbox users
4. **A-2: Multi-platform defaults/scry_2.toml** — low effort, high clarity for Windows users
5. **E-3: install.bat pre-flight check** — prevents opaque Windows install failures
6. **D-4: Intel Mac auto-update** — decide: add CI build or document as unsupported
7. **E-1: scripts/release error message** — trivial clarity improvement

## What's Working Well

- **`Scry2.Platform` as single source of truth** — excellent centralization, no `:os.type()` leakage
- **`Path.join` used consistently** — handles separators correctly across all platforms
- **TOML literal strings for Windows paths** — recently fixed correctly (commit 2f56403)
- **Go build tags** — clean platform separation in tray binary
- **Epoch-based log rotation** (ADR-032) — avoids inode reliability issues entirely
- **Separate install/data directories on Windows** — `LOCALAPPDATA` for binaries, `APPDATA` for data
- **Go tray CI runs on all 3 platforms** — good coverage
- **`dataDirFn` testable pattern** in Go platform files — allows test overrides
