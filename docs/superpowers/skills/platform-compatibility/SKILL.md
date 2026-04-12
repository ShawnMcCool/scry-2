---
name: platform-compatibility
description: "Use this skill before any work on file paths, config, platform detection, install scripts, tray binary, or CI/CD. Contains canonical rules for cross-platform correctness in both Elixir and Go — path conventions, TOML escaping, OS detection, and a verification checklist."
---

## Platform Architecture

**Single source of truth:** `Scry2.Platform` (`lib/scry_2/platform.ex`) owns all OS-specific filesystem paths. No other Elixir module calls `:os.type()` or references OS-specific directory conventions. Everything goes through `Platform`.

**Go tray mirror:** The Go tray binary mirrors platform paths via build-tag-separated files: `data_dir_linux.go`, `data_dir_darwin.go`, `data_dir_windows.go`. These **must stay in sync** with `Scry2.Platform`. Each file has a "Must stay in sync" comment — update both sides when changing paths.

**Platform detection:**
- Elixir: `:os.type()` returns `{:win32, _}`, `{:unix, :darwin}`, or `{:unix, _}` (Linux default)
- Go: `runtime.GOOS` returns `"windows"`, `"darwin"`, `"linux"`

## Canonical Rules

### Elixir Paths

1. **Always use `Path.join/1` or `Path.join/2`** for constructing paths. Never string-concatenate with `/` or `\`.

2. **Never hardcode path separators.** `Path.join` handles OS-native separators.

3. **Windows data/config paths: use `System.get_env("APPDATA")`** with `System.user_home!()` as fallback. Never use `Path.expand("~")` for Windows config/data paths — `~` expands to `USERPROFILE`, which may differ from `APPDATA` in enterprise environments with redirected profiles.

4. **TOML config values containing Windows paths must use literal strings** (single quotes). Double-quoted TOML strings interpret `\` as escape sequences, corrupting paths like `C:\Users\...` into `C:<TAB>sers\...`.

   ```toml
   # WRONG — \U is a Unicode escape in TOML
   path = "C:\Users\player\AppData\scry_2\scry_2.db"

   # CORRECT — single-quoted literal string, no escaping
   path = 'C:\Users\player\AppData\scry_2\scry_2.db'
   ```

5. **All new platform-specific path functions go in `Scry2.Platform`** — never scatter `:os.type()` checks across modules.

6. **Candidate path lists should be filtered by OS** when the list differs significantly per platform (see `mtga_raw_dir_candidates/0`). Returning all candidates unconditionally is acceptable when the list is short and callers filter with `File.regular?/1`.

7. **`Path.expand/1`** is called on all TOML-loaded paths in `Config.merge_toml/2`. On Windows, `~` expands to `USERPROFILE`. This is correct for user-entered overrides in config.toml.

### Go Paths

8. **Use `filepath.Join`** (not `path.Join`) for filesystem paths. `filepath` uses OS-native separators; `path` always uses forward slashes.

9. **Use `os.UserHomeDir()`** for home directory, `os.Getenv("APPDATA")` for Windows app data.

10. **Platform-specific code uses build tags** (`//go:build windows`, etc.), not runtime `if` checks. Exception: `runtime.GOOS` is acceptable for small suffix decisions like `.bat` extension in `resolveBackendBin()`.

11. **Make platform functions testable** via `var dataDirFn = func() string { ... }` pattern — allows test overrides without build tag complications.

### Config & Install

12. **Bootstrap config generation** (`Config.init_if_needed!/0`) writes TOML. Windows paths MUST be wrapped in TOML literal strings (single quotes). This was broken before commit 2f56403 and has a regression test.

13. **`defaults/scry_2.toml`** is documentation-only, never loaded at runtime. Keep it valid TOML with comments showing paths for all platforms.

14. **Install mechanisms per platform:**
    - Linux: `scripts/install-linux` — XDG autostart `.desktop` file, install to `~/.local/lib/scry_2/`
    - macOS: `scripts/install-macos` — LaunchAgent plist, install to `~/.local/lib/scry_2/`
    - Windows: `rel/overlays/install.bat` — Registry `HKCU\...\Run` key, install to `%LOCALAPPDATA%\scry_2\`

15. **The install/data directory separation on Windows is intentional.** Install dir (`%LOCALAPPDATA%\scry_2`) is removed on uninstall. Data dir (`%APPDATA%\scry_2`) is preserved — database and config survive reinstall.

## Cross-Platform Verification Checklist

When modifying platform-related code, verify:

- [ ] Does the change touch `Scry2.Platform`? If not, should it? All OS-specific paths must go through Platform.
- [ ] Are all three OS branches handled? `{:win32, _}`, `{:unix, :darwin}`, `{:unix, _}` in Elixir; build tags in Go.
- [ ] Does the Go tray need a matching change? Check `data_dir_*.go`, `autostart_*.go`, `browser_*.go`.
- [ ] If writing TOML with Windows paths, are literal strings (single quotes) used?
- [ ] If adding a new path, is `Path.join` used (not string concatenation)?
- [ ] If adding a new MTGA candidate path, does it cover Steam, standalone installer, and platform variants?
- [ ] If adding a new platform-specific Go function, is it using the `var fn = func() { ... }` testable pattern?
- [ ] Does `tray-ci.yml` already test the Go change on all platforms? If adding Elixir platform logic, is there a unit test that exercises all branches?
- [ ] If modifying install scripts, are all three install mechanisms updated consistently?

## Known Platform Differences

| Topic | Linux | macOS | Windows |
|-------|-------|-------|---------|
| Config dir | `~/.config/scry_2/` | `~/.config/scry_2/` | `%APPDATA%\scry_2\` |
| Data dir | `~/.local/share/scry_2/` | `~/Library/Application Support/scry_2/` | `%APPDATA%\scry_2\` |
| Install dir | `~/.local/lib/scry_2/` | `~/.local/lib/scry_2/` | `%LOCALAPPDATA%\scry_2\` |
| Database | `~/.local/share/scry_2/scry_2.db` | `~/Library/Application Support/scry_2/scry_2.db` | `%APPDATA%\scry_2\scry_2.db` |
| Autostart | XDG `.desktop` file | LaunchAgent plist | Registry `HKCU\...\Run` |
| File watcher | inotify (`:file_system`) | FSEvents (`:file_system`) | ReadDirectoryChangesW (`:file_system`) |
| File locking | Advisory (shared) | Advisory (shared) | Mandatory (MTGA opens with share-read) |
| Inode reliability | Reliable | Reliable | Unreliable (may return 0 under Wine/NTFS) |
| Rotation detection | Size comparison | Size comparison | Size comparison |
| Process management | `pgrep`/`pkill` | `launchctl` + `pkill` | `taskkill` |
| Release binary | `bin/scry_2` | `bin/scry_2` | `bin\scry_2.bat` |
| Archive format | `.tar.gz` | `.tar.gz` | `.zip` |
| Browser open | `xdg-open` | `open` | `cmd /c start` |
| Tray dependency | `libayatana-appindicator3` | None | None |

## Gotchas

1. **TOML backslash escaping.** `path = "C:\Users\..."` in double-quoted TOML interprets `\U` as a Unicode escape. Use `path = 'C:\Users\...'` (single-quoted literal string). This broke bootstrap config before commit 2f56403.

2. **`Path.expand("~")` on Windows** returns `USERPROFILE`, not `APPDATA`. These can differ if enterprise profile redirection is active. `Scry2.Platform` explicitly uses `System.get_env("APPDATA")` — don't substitute `Path.expand("~")`.

3. **Inode on Windows/Wine.** `File.stat/1` may return `inode: 0` or reuse inodes across different files. Never use inode for file identity. The epoch counter (ADR-032) is the correct mechanism.

4. **`scripts/release` is Unix-only.** Windows release builds happen exclusively in CI (`release.yml`). Don't try to add a Windows case to `scripts/release`.

5. **Windows firewall.** `epmd.exe` and `erl.exe` trigger firewall prompts. Scry2 doesn't use distributed Erlang in production, so these can be blocked without affecting local operation — but Windows still prompts. Document this for users.

6. **macOS Gatekeeper.** Unsigned binaries trigger "unidentified developer" warnings. Users must right-click > Open or run `xattr -cr` on the extracted package. Document in release notes.

7. **Linux tray icon.** GNOME requires `gnome-shell-extension-appindicator` for system tray support. Without it, the tray icon is invisible (but Scry2 still runs).

8. **`cmd /c start` URL encoding.** If the dashboard URL ever gains query parameters containing `&`, the Windows browser opener will break (treats `&` as command separator). The current hardcoded `http://localhost:6015` is safe.
