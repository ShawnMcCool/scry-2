//! Read MTGA's build GUID from `<MTGA root>/MTGA_Data/boot.config`.
//!
//! `boot.config` is a Unity-managed key=value file written at install
//! time. The `build-guid` line uniquely identifies a specific MTGA
//! build and is useful as a sanity check on top of walker output:
//! when the build GUID changes between runs, the walker offsets may
//! have shifted and a re-verification pass against the
//! `mono-memory-reader` skill's recipe is warranted.
//!
//! This module is **disk-only** — it does not read the target
//! process's memory. The pieces are split so unit tests can drive
//! `parse_build_guid` and `find_mtga_root` without touching the
//! filesystem; the composing `read_build_guid` is the only function
//! that actually opens a file.

use std::path::{Path, PathBuf};

use super::run::MapEntry;

/// Filename of the Mono DLL — used to recognise the MTGA install
/// root from `/proc/<pid>/maps` paths.
pub const MONO_DLL_FILENAME: &str = "mono-2.0-bdwgc.dll";

/// Subpath under the MTGA install root that holds `boot.config`.
pub const BOOT_CONFIG_SUBPATH: &str = "MTGA_Data/boot.config";

/// `Path::ancestors().nth(N)` value that walks from the Mono DLL
/// path up to the MTGA install root: 0 = the file itself, 1 =
/// `EmbedRuntime`, 2 = `MonoBleedingEdge`, 3 = MTGA root.
const MTGA_ROOT_ANCESTOR_INDEX: usize = 3;

/// Walk a `/proc/<pid>/maps` snapshot looking for a path whose
/// basename equals [`MONO_DLL_FILENAME`] (case-insensitive — Wine
/// happily preserves whatever case the Windows installer wrote).
/// Return the MTGA install root by walking up three components from
/// that file.
pub fn find_mtga_root(maps: &[MapEntry]) -> Option<PathBuf> {
    for (_, _, _, path) in maps {
        let path_str = match path.as_deref() {
            Some(p) => p,
            None => continue,
        };
        let basename = Path::new(path_str).file_name()?.to_string_lossy();
        if !basename.eq_ignore_ascii_case(MONO_DLL_FILENAME) {
            continue;
        }
        let root = Path::new(path_str)
            .ancestors()
            .nth(MTGA_ROOT_ANCESTOR_INDEX)?;
        return Some(root.to_path_buf());
    }
    None
}

/// Read `<mtga_root>/MTGA_Data/boot.config` from disk and return
/// the `build-guid=…` value. Returns `None` on any read or parse
/// failure.
pub fn read_build_guid(mtga_root: &Path) -> Option<String> {
    let path = mtga_root.join(BOOT_CONFIG_SUBPATH);
    let contents = std::fs::read_to_string(path).ok()?;
    parse_build_guid(&contents)
}

/// Extract the `build-guid` value from boot.config contents.
/// Accepts both `build-guid=value` and `build-guid: value` line
/// shapes. Empty values are reported as `None`.
pub fn parse_build_guid(contents: &str) -> Option<String> {
    for line in contents.lines() {
        let trimmed = line.trim();
        let rest = match trimmed
            .strip_prefix("build-guid=")
            .or_else(|| trimmed.strip_prefix("build-guid:"))
        {
            Some(r) => r,
            None => continue,
        };
        let value = rest.trim();
        if !value.is_empty() {
            return Some(value.to_string());
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unix_dll_entry(path: &str) -> MapEntry {
        (0, 0x1000, "r-xp".to_string(), Some(path.to_string()))
    }

    #[test]
    fn parse_build_guid_finds_equals_form() {
        let contents = "scripting-runtime-version=latest\n\
                        vr-enabled=0\n\
                        build-guid=abc123def456\n\
                        gc-max-time-slice=3\n";
        assert_eq!(parse_build_guid(contents).as_deref(), Some("abc123def456"));
    }

    #[test]
    fn parse_build_guid_finds_colon_form() {
        // Some Unity versions use ":" instead of "=" — be liberal.
        let contents = "build-guid: deadbeef1234\n";
        assert_eq!(parse_build_guid(contents).as_deref(), Some("deadbeef1234"));
    }

    #[test]
    fn parse_build_guid_trims_surrounding_whitespace() {
        let contents = "  build-guid=  abc-123  \n";
        assert_eq!(parse_build_guid(contents).as_deref(), Some("abc-123"));
    }

    #[test]
    fn parse_build_guid_returns_none_when_absent() {
        let contents = "scripting-runtime-version=latest\nvr-enabled=0\n";
        assert!(parse_build_guid(contents).is_none());
    }

    #[test]
    fn parse_build_guid_returns_none_for_empty_value() {
        let contents = "build-guid=\nother-key=value\n";
        assert!(parse_build_guid(contents).is_none());
    }

    #[test]
    fn parse_build_guid_returns_none_for_empty_input() {
        assert!(parse_build_guid("").is_none());
    }

    #[test]
    fn parse_build_guid_returns_first_match_when_duplicates_exist() {
        let contents = "build-guid=first\nbuild-guid=second\n";
        assert_eq!(parse_build_guid(contents).as_deref(), Some("first"));
    }

    #[test]
    fn parse_build_guid_does_not_match_substring_keys() {
        // `pre-build-guid=…` and `xbuild-guid=…` must not match.
        let contents =
            "pre-build-guid=junk\nxbuild-guid=junk2\nbuild-guid-x=junk3\nbuild-guid=real\n";
        assert_eq!(parse_build_guid(contents).as_deref(), Some("real"));
    }

    #[test]
    fn find_mtga_root_resolves_unix_path() -> Result<(), String> {
        let maps = vec![unix_dll_entry(
            "/home/u/.steam/steamapps/common/MTGA/MonoBleedingEdge/EmbedRuntime/mono-2.0-bdwgc.dll",
        )];
        let root = find_mtga_root(&maps).ok_or("must resolve")?;
        assert_eq!(root, PathBuf::from("/home/u/.steam/steamapps/common/MTGA"));
        Ok(())
    }

    #[test]
    fn find_mtga_root_handles_uppercase_basename() -> Result<(), String> {
        let maps = vec![unix_dll_entry(
            "/path/to/MTGA/MonoBleedingEdge/EmbedRuntime/MONO-2.0-BDWGC.DLL",
        )];
        let root = find_mtga_root(&maps).ok_or("must resolve")?;
        assert_eq!(root, PathBuf::from("/path/to/MTGA"));
        Ok(())
    }

    #[test]
    fn find_mtga_root_skips_unrelated_modules() -> Result<(), String> {
        let maps = vec![
            unix_dll_entry("/lib/libc.so.6"),
            unix_dll_entry("/path/to/MTGA/MonoBleedingEdge/EmbedRuntime/mono-2.0-bdwgc.dll"),
            unix_dll_entry("/lib/some-other.so"),
        ];
        let root = find_mtga_root(&maps).ok_or("must resolve via second entry")?;
        assert_eq!(root, PathBuf::from("/path/to/MTGA"));
        Ok(())
    }

    #[test]
    fn find_mtga_root_returns_none_when_dll_missing() {
        let maps = vec![
            unix_dll_entry("/lib/libc.so.6"),
            unix_dll_entry("/lib/some-other.so"),
        ];
        assert!(find_mtga_root(&maps).is_none());
    }

    #[test]
    fn find_mtga_root_returns_none_when_no_path() {
        let maps = vec![(0, 0x1000, "r-xp".to_string(), None)];
        assert!(find_mtga_root(&maps).is_none());
    }

    #[test]
    fn read_build_guid_reads_from_disk() -> Result<(), Box<dyn std::error::Error>> {
        // Write a transient boot.config under a tempdir and verify
        // read_build_guid returns the expected value.
        let dir = tempdir()?;
        let mtga_data = dir.path().join("MTGA_Data");
        std::fs::create_dir_all(&mtga_data)?;
        std::fs::write(
            mtga_data.join("boot.config"),
            "scripting-runtime-version=latest\nbuild-guid=disk-test-guid\n",
        )?;

        let got = read_build_guid(dir.path()).ok_or("must read build-guid")?;
        assert_eq!(got, "disk-test-guid");
        Ok(())
    }

    #[test]
    fn read_build_guid_returns_none_when_file_missing() -> Result<(), Box<dyn std::error::Error>> {
        let dir = tempdir()?;
        // No MTGA_Data/boot.config → None.
        assert!(read_build_guid(dir.path()).is_none());
        Ok(())
    }

    /// Tiny tempdir helper that respects $TMPDIR and cleans up on
    /// drop. Avoids pulling in the `tempfile` crate for one test.
    struct TempDir(PathBuf);

    impl TempDir {
        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn tempdir() -> std::io::Result<TempDir> {
        // Hand-rolled unique-name tempdir: $TMPDIR/scry2_walker_<nanos>
        let base = std::env::temp_dir();
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let dir = base.join(format!("scry2_walker_{}", nanos));
        std::fs::create_dir_all(&dir)?;
        Ok(TempDir(dir))
    }
}
