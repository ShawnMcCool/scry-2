//! Walk a Portable Executable's export directory to look up a named
//! function's RVA.
//!
//! Input is the raw bytes of a loaded DLL as mapped in the target
//! process. Because the loader places each section at its
//! `VirtualAddress`, every RVA inside the PE structures is a direct
//! offset into this buffer.
//!
//! The parser is deliberately minimal: it accepts only PE32+ images
//! (`mono-2.0-bdwgc.dll` is 64-bit, and there is no use case for the
//! 32-bit variant) and returns `None` on any malformed, truncated, or
//! out-of-bounds structure rather than panicking.
//!
//! Forwarded exports — where the function RVA points back inside the
//! export directory at an ASCII forwarder string — are reported as
//! `None`. The walker only consumes real code RVAs.

const DOS_MAGIC: u16 = 0x5a4d; // "MZ"
const PE_SIGNATURE: u32 = 0x0000_4550; // "PE\0\0"
const PE32_PLUS_MAGIC: u16 = 0x20b;

const E_LFANEW_OFFSET: usize = 0x3c;
const COFF_HEADER_LEN: usize = 20;

// Offsets inside the PE32+ Optional Header.
//
// Standard fields (24 bytes) followed by Windows-specific fields
// (88 bytes), so NumberOfRvaAndSizes lives at 108 and the
// DataDirectories array begins at 112.
const OPT_MAGIC_OFFSET: usize = 0;
const OPT_NUMBER_OF_RVA_AND_SIZES_OFFSET: usize = 108;
const OPT_DATA_DIR_OFFSET: usize = 112;

// Export Directory Table layout (40 bytes total).
const EXPORT_DIR_LEN: usize = 40;
const EXP_NUMBER_OF_FUNCTIONS_OFFSET: usize = 20;
const EXP_NUMBER_OF_NAMES_OFFSET: usize = 24;
const EXP_ADDRESS_OF_FUNCTIONS_OFFSET: usize = 28;
const EXP_ADDRESS_OF_NAMES_OFFSET: usize = 32;
const EXP_ADDRESS_OF_NAME_ORDINALS_OFFSET: usize = 36;

/// Look up the RVA of a named export in a mapped PE32+ image.
///
/// Returns `None` if `bytes` is not a PE32+ image, the export
/// directory is empty or out of bounds, the requested name is missing,
/// or the matched export is a forwarder.
pub fn find_export_rva(bytes: &[u8], name: &str) -> Option<u32> {
    if read_u16(bytes, 0)? != DOS_MAGIC {
        return None;
    }

    let e_lfanew = read_u32(bytes, E_LFANEW_OFFSET)? as usize;
    if read_u32(bytes, e_lfanew)? != PE_SIGNATURE {
        return None;
    }

    let coff_off = e_lfanew.checked_add(4)?;
    let opt_off = coff_off.checked_add(COFF_HEADER_LEN)?;

    if read_u16(bytes, opt_off.checked_add(OPT_MAGIC_OFFSET)?)? != PE32_PLUS_MAGIC {
        return None;
    }

    let n_dirs_off = opt_off.checked_add(OPT_NUMBER_OF_RVA_AND_SIZES_OFFSET)?;
    if read_u32(bytes, n_dirs_off)? == 0 {
        return None;
    }

    let data_dir_off = opt_off.checked_add(OPT_DATA_DIR_OFFSET)?;
    let export_dir_rva = read_u32(bytes, data_dir_off)?;
    let export_dir_size = read_u32(bytes, data_dir_off.checked_add(4)?)?;
    if export_dir_rva == 0 || export_dir_size == 0 {
        return None;
    }

    let exp_off = export_dir_rva as usize;
    bytes.get(exp_off..exp_off.checked_add(EXPORT_DIR_LEN)?)?;

    let n_funcs = read_u32(bytes, exp_off.checked_add(EXP_NUMBER_OF_FUNCTIONS_OFFSET)?)? as usize;
    let n_names = read_u32(bytes, exp_off.checked_add(EXP_NUMBER_OF_NAMES_OFFSET)?)? as usize;
    let addr_funcs =
        read_u32(bytes, exp_off.checked_add(EXP_ADDRESS_OF_FUNCTIONS_OFFSET)?)? as usize;
    let addr_names = read_u32(bytes, exp_off.checked_add(EXP_ADDRESS_OF_NAMES_OFFSET)?)? as usize;
    let addr_ords = read_u32(
        bytes,
        exp_off.checked_add(EXP_ADDRESS_OF_NAME_ORDINALS_OFFSET)?,
    )? as usize;

    // Bounds-check every parallel array up front so the per-name loop
    // body can use direct offsets without repeating the work.
    bytes.get(addr_names..addr_names.checked_add(n_names.checked_mul(4)?)?)?;
    bytes.get(addr_ords..addr_ords.checked_add(n_names.checked_mul(2)?)?)?;
    bytes.get(addr_funcs..addr_funcs.checked_add(n_funcs.checked_mul(4)?)?)?;

    let target = name.as_bytes();
    let exp_end = exp_off.checked_add(export_dir_size as usize)?;

    for i in 0..n_names {
        let name_rva = read_u32(bytes, addr_names.checked_add(i.checked_mul(4)?)?)? as usize;
        if !cstr_equals(bytes, name_rva, target) {
            continue;
        }

        let ord = read_u16(bytes, addr_ords.checked_add(i.checked_mul(2)?)?)? as usize;
        if ord >= n_funcs {
            return None;
        }

        let fn_rva = read_u32(bytes, addr_funcs.checked_add(ord.checked_mul(4)?)?)?;

        // Forwarder: the export RVA falls inside the export directory's
        // own range and points at an ASCII "Module.Name" string. Not
        // useful for the walker.
        if (fn_rva as usize) >= exp_off && (fn_rva as usize) < exp_end {
            return None;
        }

        return Some(fn_rva);
    }

    None
}

fn read_u16(bytes: &[u8], offset: usize) -> Option<u16> {
    let end = offset.checked_add(2)?;
    let slice = bytes.get(offset..end)?;
    Some(u16::from_le_bytes([slice[0], slice[1]]))
}

fn read_u32(bytes: &[u8], offset: usize) -> Option<u32> {
    let end = offset.checked_add(4)?;
    let slice = bytes.get(offset..end)?;
    Some(u32::from_le_bytes([slice[0], slice[1], slice[2], slice[3]]))
}

/// Compare a NUL-terminated C string at `offset` against `target`,
/// returning `true` only if the bytes match exactly and the next byte
/// is `0x00`. Out-of-bounds offsets and arithmetic overflow yield
/// `false`.
fn cstr_equals(bytes: &[u8], offset: usize, target: &[u8]) -> bool {
    let Some(end) = offset
        .checked_add(target.len())
        .and_then(|n| n.checked_add(1))
    else {
        return false;
    };
    let Some(slice) = bytes.get(offset..end) else {
        return false;
    };
    &slice[..target.len()] == target && slice[target.len()] == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Layout constants chosen so every structure lives in a clean,
    /// non-overlapping region of a 4 KiB buffer.
    const E_LFANEW: usize = 0x80;
    const OPT_OFF: usize = E_LFANEW + 4 + COFF_HEADER_LEN; // 0x98
    const EXPORT_DIR_RVA: usize = 0x200;
    const EXPORT_DIR_SIZE: u32 = 0x80;
    const NAMES_RVA: usize = 0x300;
    const ORDS_RVA: usize = 0x340;
    const FUNCS_RVA: usize = 0x380;
    const STRINGS_RVA: usize = 0x400;
    const TOTAL_SIZE: usize = 0x1000;

    struct Builder {
        bytes: Vec<u8>,
    }

    impl Builder {
        fn new() -> Self {
            Self {
                bytes: vec![0u8; TOTAL_SIZE],
            }
        }

        fn u16(&mut self, off: usize, v: u16) -> &mut Self {
            self.bytes[off..off + 2].copy_from_slice(&v.to_le_bytes());
            self
        }

        fn u32(&mut self, off: usize, v: u32) -> &mut Self {
            self.bytes[off..off + 4].copy_from_slice(&v.to_le_bytes());
            self
        }

        fn cstr(&mut self, off: usize, s: &str) -> &mut Self {
            let b = s.as_bytes();
            self.bytes[off..off + b.len()].copy_from_slice(b);
            self.bytes[off + b.len()] = 0;
            self
        }

        fn done(self) -> Vec<u8> {
            self.bytes
        }
    }

    /// Headers up through the optional header magic and data
    /// directory count, with the export data directory pointing at
    /// `EXPORT_DIR_RVA`.
    fn write_pe_headers(b: &mut Builder, opt_magic: u16) {
        b.u16(0, DOS_MAGIC)
            .u32(0x3c, E_LFANEW as u32)
            .u32(E_LFANEW, PE_SIGNATURE)
            .u16(OPT_OFF + OPT_MAGIC_OFFSET, opt_magic)
            .u32(OPT_OFF + OPT_NUMBER_OF_RVA_AND_SIZES_OFFSET, 16)
            .u32(OPT_OFF + OPT_DATA_DIR_OFFSET, EXPORT_DIR_RVA as u32)
            .u32(OPT_OFF + OPT_DATA_DIR_OFFSET + 4, EXPORT_DIR_SIZE);
    }

    /// Build a minimal valid PE32+ image exporting one named function
    /// at `fn_rva`.
    fn synth_single_export(name: &str, fn_rva: u32) -> Vec<u8> {
        let mut b = Builder::new();
        write_pe_headers(&mut b, PE32_PLUS_MAGIC);
        b.u32(EXPORT_DIR_RVA + EXP_NUMBER_OF_FUNCTIONS_OFFSET, 1)
            .u32(EXPORT_DIR_RVA + EXP_NUMBER_OF_NAMES_OFFSET, 1)
            .u32(
                EXPORT_DIR_RVA + EXP_ADDRESS_OF_FUNCTIONS_OFFSET,
                FUNCS_RVA as u32,
            )
            .u32(
                EXPORT_DIR_RVA + EXP_ADDRESS_OF_NAMES_OFFSET,
                NAMES_RVA as u32,
            )
            .u32(
                EXPORT_DIR_RVA + EXP_ADDRESS_OF_NAME_ORDINALS_OFFSET,
                ORDS_RVA as u32,
            )
            .u32(NAMES_RVA, STRINGS_RVA as u32)
            .u16(ORDS_RVA, 0)
            .u32(FUNCS_RVA, fn_rva)
            .cstr(STRINGS_RVA, name);
        b.done()
    }

    /// Build a PE32+ image with three named exports laid out in
    /// alphabetical order. Returns `(bytes, fn_rvas)`.
    fn synth_three_exports() -> (Vec<u8>, [u32; 3]) {
        let names = ["alpha_func", "mono_get_root_domain", "zeta_func"];
        let fn_rvas = [0x1111_u32, 0x2222, 0x3333];
        let str_offsets = [STRINGS_RVA, STRINGS_RVA + 0x40, STRINGS_RVA + 0x80];

        let mut b = Builder::new();
        write_pe_headers(&mut b, PE32_PLUS_MAGIC);
        b.u32(EXPORT_DIR_RVA + EXP_NUMBER_OF_FUNCTIONS_OFFSET, 3)
            .u32(EXPORT_DIR_RVA + EXP_NUMBER_OF_NAMES_OFFSET, 3)
            .u32(
                EXPORT_DIR_RVA + EXP_ADDRESS_OF_FUNCTIONS_OFFSET,
                FUNCS_RVA as u32,
            )
            .u32(
                EXPORT_DIR_RVA + EXP_ADDRESS_OF_NAMES_OFFSET,
                NAMES_RVA as u32,
            )
            .u32(
                EXPORT_DIR_RVA + EXP_ADDRESS_OF_NAME_ORDINALS_OFFSET,
                ORDS_RVA as u32,
            );
        for i in 0..3 {
            b.u32(NAMES_RVA + i * 4, str_offsets[i] as u32)
                .u16(ORDS_RVA + i * 2, i as u16)
                .u32(FUNCS_RVA + i * 4, fn_rvas[i])
                .cstr(str_offsets[i], names[i]);
        }
        (b.done(), fn_rvas)
    }

    #[test]
    fn finds_single_named_export() {
        let bytes = synth_single_export("mono_get_root_domain", 0x1234);
        assert_eq!(
            find_export_rva(&bytes, "mono_get_root_domain"),
            Some(0x1234)
        );
    }

    #[test]
    fn finds_correct_export_among_several() {
        let (bytes, rvas) = synth_three_exports();
        assert_eq!(find_export_rva(&bytes, "alpha_func"), Some(rvas[0]));
        assert_eq!(
            find_export_rva(&bytes, "mono_get_root_domain"),
            Some(rvas[1])
        );
        assert_eq!(find_export_rva(&bytes, "zeta_func"), Some(rvas[2]));
    }

    #[test]
    fn returns_none_for_unknown_name() {
        let bytes = synth_single_export("mono_get_root_domain", 0x1234);
        assert_eq!(find_export_rva(&bytes, "missing_symbol"), None);
    }

    #[test]
    fn does_not_match_prefix() {
        // "mono_get_root" is a strict prefix of the actual name; the
        // null-terminator check must reject it.
        let bytes = synth_single_export("mono_get_root_domain", 0x1234);
        assert_eq!(find_export_rva(&bytes, "mono_get_root"), None);
    }

    #[test]
    fn rejects_missing_dos_magic() {
        let mut bytes = synth_single_export("mono_get_root_domain", 0x1234);
        bytes[0] = 0x00;
        bytes[1] = 0x00;
        assert_eq!(find_export_rva(&bytes, "mono_get_root_domain"), None);
    }

    #[test]
    fn rejects_missing_pe_signature() {
        let mut bytes = synth_single_export("mono_get_root_domain", 0x1234);
        bytes[E_LFANEW] = 0x00;
        assert_eq!(find_export_rva(&bytes, "mono_get_root_domain"), None);
    }

    #[test]
    fn rejects_pe32_image() {
        // Only PE32+ (0x20b) is supported. PE32 (0x10b) must be
        // refused even if the rest of the structure looks plausible.
        let mut b = Builder::new();
        write_pe_headers(&mut b, 0x10b);
        let bytes = b.done();
        assert_eq!(find_export_rva(&bytes, "anything"), None);
    }

    #[test]
    fn rejects_zero_data_directories() {
        let mut bytes = synth_single_export("mono_get_root_domain", 0x1234);
        let n_dirs_off = OPT_OFF + OPT_NUMBER_OF_RVA_AND_SIZES_OFFSET;
        bytes[n_dirs_off..n_dirs_off + 4].copy_from_slice(&0u32.to_le_bytes());
        assert_eq!(find_export_rva(&bytes, "mono_get_root_domain"), None);
    }

    #[test]
    fn rejects_empty_export_directory() {
        let mut bytes = synth_single_export("mono_get_root_domain", 0x1234);
        let dd = OPT_OFF + OPT_DATA_DIR_OFFSET;
        bytes[dd..dd + 4].copy_from_slice(&0u32.to_le_bytes());
        bytes[dd + 4..dd + 8].copy_from_slice(&0u32.to_le_bytes());
        assert_eq!(find_export_rva(&bytes, "mono_get_root_domain"), None);
    }

    #[test]
    fn rejects_export_directory_past_end_of_buffer() {
        let mut bytes = synth_single_export("mono_get_root_domain", 0x1234);
        let dd = OPT_OFF + OPT_DATA_DIR_OFFSET;
        bytes[dd..dd + 4].copy_from_slice(&(TOTAL_SIZE as u32 + 0x100).to_le_bytes());
        assert_eq!(find_export_rva(&bytes, "mono_get_root_domain"), None);
    }

    #[test]
    fn rejects_truncated_buffer() {
        let bytes = synth_single_export("mono_get_root_domain", 0x1234);
        // Truncate before the export directory but after headers.
        let truncated = &bytes[..0x180];
        assert_eq!(find_export_rva(truncated, "mono_get_root_domain"), None);
    }

    #[test]
    fn rejects_forwarded_export() {
        // Place the function RVA inside the export directory's range
        // so it looks like a forwarder string ("KERNEL32.LoadLibraryA"
        // pattern). The walker must report None rather than handing
        // back a string offset masquerading as code.
        let bytes = synth_single_export("forwarded_func", (EXPORT_DIR_RVA + 0x10) as u32);
        assert_eq!(find_export_rva(&bytes, "forwarded_func"), None);
    }

    #[test]
    fn rejects_ordinal_out_of_range() {
        let mut bytes = synth_single_export("mono_get_root_domain", 0x1234);
        bytes[ORDS_RVA..ORDS_RVA + 2].copy_from_slice(&5u16.to_le_bytes());
        assert_eq!(find_export_rva(&bytes, "mono_get_root_domain"), None);
    }

    #[test]
    fn rejects_name_rva_out_of_bounds() {
        let mut bytes = synth_single_export("mono_get_root_domain", 0x1234);
        bytes[NAMES_RVA..NAMES_RVA + 4].copy_from_slice(&(TOTAL_SIZE as u32 + 0x100).to_le_bytes());
        assert_eq!(find_export_rva(&bytes, "mono_get_root_domain"), None);
    }

    #[test]
    fn rejects_empty_buffer() {
        assert_eq!(find_export_rva(&[], "anything"), None);
    }
}
