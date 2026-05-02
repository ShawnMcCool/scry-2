//! Resolve the live `MonoDomain *` from a mapped `mono-2.0-bdwgc.dll`.
//!
//! Composes the lower-level helpers in this crate:
//!
//! 1. [`pe::find_export_rva`] — look up the RVA of
//!    `mono_get_root_domain` in the mapped PE32+ image.
//! 2. [`prologue::parse_mov_rax_rip_ret`] — decode the
//!    `mov rax, [rip+disp32]; ret` accessor body to compute the
//!    absolute address of the static `MonoDomain *` pointer.
//! 3. A single 8-byte read against the target process to dereference
//!    that static pointer and obtain the live `MonoDomain *`.
//!
//! The function takes a `read_mem` closure — the same shape used by
//! the rest of the walker — so it can run against `process_vm_readv`
//! in production and a `FakeMem`-style stub in tests.

use super::{pe, prologue};

/// Name of the Mono export this module decodes.
pub const ROOT_DOMAIN_SYMBOL: &str = "mono_get_root_domain";

/// Locate the live `MonoDomain *` in the target process.
///
/// `mono_dll_bytes` is the byte image of `mono-2.0-bdwgc.dll` as
/// mapped (loader-applied section placement; every RVA is a direct
/// offset into the buffer). `mono_dll_base` is the module's remote
/// base address — the absolute address at which the loader placed
/// the image.
///
/// Returns `None` when the export can't be found, the prologue
/// doesn't match the expected `mov rax,[rip+disp32]; ret` shape, the
/// address arithmetic would wrap, or the static pointer can't be
/// read. A returned `Some(0)` would only happen if Mono publishes a
/// null root domain (it doesn't, in practice); we report `None` in
/// that case so callers don't have to second-guess.
pub fn find_root_domain<F>(mono_dll_bytes: &[u8], mono_dll_base: u64, read_mem: F) -> Option<u64>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let fn_rva = pe::find_export_rva(mono_dll_bytes, ROOT_DOMAIN_SYMBOL)?;
    let fn_off = fn_rva as usize;
    let body = mono_dll_bytes.get(fn_off..fn_off.checked_add(prologue::PROLOGUE_LEN)?)?;
    let fn_addr = mono_dll_base.checked_add(fn_rva as u64)?;
    let static_ptr_addr = prologue::parse_mov_rax_rip_ret(body, fn_addr)?;

    let buf = read_mem(static_ptr_addr, 8)?;
    if buf.len() < 8 {
        return None;
    }
    let domain_ptr = u64::from_le_bytes([
        buf[0], buf[1], buf[2], buf[3], buf[4], buf[5], buf[6], buf[7],
    ]);
    if domain_ptr == 0 {
        None
    } else {
        Some(domain_ptr)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// PE layout knobs duplicated from `pe::tests` so we can synth a
    /// minimal valid PE32+ image without exposing PE internals as
    /// public API. Numbers picked to leave room for the prologue
    /// bytes inside the function-region of the buffer.
    const TOTAL_SIZE: usize = 0x2000;
    const E_LFANEW: usize = 0x80;
    const COFF_HEADER_LEN: usize = 20;
    const OPT_OFF: usize = E_LFANEW + 4 + COFF_HEADER_LEN; // 0x98
    const EXPORT_DIR_RVA: usize = 0x200;
    const EXPORT_DIR_SIZE: u32 = 0x80;
    const NAMES_RVA: usize = 0x300;
    const ORDS_RVA: usize = 0x340;
    const FUNCS_RVA: usize = 0x380;
    const STRINGS_RVA: usize = 0x400;
    const FN_RVA: u32 = 0x800;

    const DOS_MAGIC: u16 = 0x5a4d;
    const PE_SIGNATURE: u32 = 0x0000_4550;
    const PE32_PLUS_MAGIC: u16 = 0x20b;
    const OPT_MAGIC_OFFSET: usize = 0;
    const OPT_NUMBER_OF_RVA_AND_SIZES_OFFSET: usize = 108;
    const OPT_DATA_DIR_OFFSET: usize = 112;
    const EXP_NUMBER_OF_FUNCTIONS_OFFSET: usize = 20;
    const EXP_NUMBER_OF_NAMES_OFFSET: usize = 24;
    const EXP_ADDRESS_OF_FUNCTIONS_OFFSET: usize = 28;
    const EXP_ADDRESS_OF_NAMES_OFFSET: usize = 32;
    const EXP_ADDRESS_OF_NAME_ORDINALS_OFFSET: usize = 36;

    use crate::walker::test_support::FakeMem;

    /// Build a minimal PE32+ image that exports `mono_get_root_domain`
    /// at `FN_RVA`, with the prologue body installed at that offset
    /// pointing at `static_ptr_rva` (relative to image base 0).
    fn build_image(static_ptr_rva: u32) -> Vec<u8> {
        let mut bytes = vec![0u8; TOTAL_SIZE];
        // DOS + PE signature
        bytes[0..2].copy_from_slice(&DOS_MAGIC.to_le_bytes());
        bytes[0x3c..0x40].copy_from_slice(&(E_LFANEW as u32).to_le_bytes());
        bytes[E_LFANEW..E_LFANEW + 4].copy_from_slice(&PE_SIGNATURE.to_le_bytes());
        // Optional header magic, NumberOfRvaAndSizes, ExportDir entry
        bytes[OPT_OFF + OPT_MAGIC_OFFSET..OPT_OFF + OPT_MAGIC_OFFSET + 2]
            .copy_from_slice(&PE32_PLUS_MAGIC.to_le_bytes());
        bytes[OPT_OFF + OPT_NUMBER_OF_RVA_AND_SIZES_OFFSET
            ..OPT_OFF + OPT_NUMBER_OF_RVA_AND_SIZES_OFFSET + 4]
            .copy_from_slice(&16u32.to_le_bytes());
        bytes[OPT_OFF + OPT_DATA_DIR_OFFSET..OPT_OFF + OPT_DATA_DIR_OFFSET + 4]
            .copy_from_slice(&(EXPORT_DIR_RVA as u32).to_le_bytes());
        bytes[OPT_OFF + OPT_DATA_DIR_OFFSET + 4..OPT_OFF + OPT_DATA_DIR_OFFSET + 8]
            .copy_from_slice(&EXPORT_DIR_SIZE.to_le_bytes());

        // Export Directory: 1 function, 1 name.
        bytes[EXPORT_DIR_RVA + EXP_NUMBER_OF_FUNCTIONS_OFFSET
            ..EXPORT_DIR_RVA + EXP_NUMBER_OF_FUNCTIONS_OFFSET + 4]
            .copy_from_slice(&1u32.to_le_bytes());
        bytes[EXPORT_DIR_RVA + EXP_NUMBER_OF_NAMES_OFFSET
            ..EXPORT_DIR_RVA + EXP_NUMBER_OF_NAMES_OFFSET + 4]
            .copy_from_slice(&1u32.to_le_bytes());
        bytes[EXPORT_DIR_RVA + EXP_ADDRESS_OF_FUNCTIONS_OFFSET
            ..EXPORT_DIR_RVA + EXP_ADDRESS_OF_FUNCTIONS_OFFSET + 4]
            .copy_from_slice(&(FUNCS_RVA as u32).to_le_bytes());
        bytes[EXPORT_DIR_RVA + EXP_ADDRESS_OF_NAMES_OFFSET
            ..EXPORT_DIR_RVA + EXP_ADDRESS_OF_NAMES_OFFSET + 4]
            .copy_from_slice(&(NAMES_RVA as u32).to_le_bytes());
        bytes[EXPORT_DIR_RVA + EXP_ADDRESS_OF_NAME_ORDINALS_OFFSET
            ..EXPORT_DIR_RVA + EXP_ADDRESS_OF_NAME_ORDINALS_OFFSET + 4]
            .copy_from_slice(&(ORDS_RVA as u32).to_le_bytes());

        // Names array → strings; ordinals array → 0; functions array → FN_RVA.
        bytes[NAMES_RVA..NAMES_RVA + 4].copy_from_slice(&(STRINGS_RVA as u32).to_le_bytes());
        bytes[ORDS_RVA..ORDS_RVA + 2].copy_from_slice(&0u16.to_le_bytes());
        bytes[FUNCS_RVA..FUNCS_RVA + 4].copy_from_slice(&FN_RVA.to_le_bytes());

        // Name string.
        let name = ROOT_DOMAIN_SYMBOL.as_bytes();
        bytes[STRINGS_RVA..STRINGS_RVA + name.len()].copy_from_slice(name);
        bytes[STRINGS_RVA + name.len()] = 0;

        // Prologue at FN_RVA: 48 8b 05 disp32 c3, where disp32 is
        // chosen so RIP-after-mov + disp = static_ptr_rva.
        // RIP-after-mov = FN_RVA + 7. So disp32 = static_ptr_rva - (FN_RVA + 7).
        let rip_after_mov = FN_RVA as i64 + 7;
        let disp32 = (static_ptr_rva as i64 - rip_after_mov) as i32;
        let disp_bytes = disp32.to_le_bytes();
        let fn_off = FN_RVA as usize;
        bytes[fn_off] = 0x48;
        bytes[fn_off + 1] = 0x8b;
        bytes[fn_off + 2] = 0x05;
        bytes[fn_off + 3] = disp_bytes[0];
        bytes[fn_off + 4] = disp_bytes[1];
        bytes[fn_off + 5] = disp_bytes[2];
        bytes[fn_off + 6] = disp_bytes[3];
        bytes[fn_off + 7] = 0xc3;

        bytes
    }

    fn run(image: &[u8], base: u64, mem: &FakeMem) -> Option<u64> {
        find_root_domain(image, base, |a, l| mem.read(a, l))
    }

    #[test]
    fn resolves_live_domain_pointer() -> Result<(), String> {
        let static_ptr_rva: u32 = 0x900;
        let image = build_image(static_ptr_rva);
        let base: u64 = 0x180000000;
        let static_ptr_addr = base + static_ptr_rva as u64;
        let domain_addr: u64 = 0x7fff_1234_5670;

        let mut mem = FakeMem::default();
        mem.add(static_ptr_addr, domain_addr.to_le_bytes().to_vec());

        let domain = run(&image, base, &mem).ok_or("domain pointer must resolve")?;
        assert_eq!(domain, domain_addr);
        Ok(())
    }

    #[test]
    fn returns_none_when_export_is_missing() {
        // Synthesize an image without the export by giving a wrong name.
        let mut image = build_image(0x900);
        // Overwrite the name string so the export search misses.
        let bad = b"some_other_export\0";
        image[STRINGS_RVA..STRINGS_RVA + bad.len()].copy_from_slice(bad);
        let mem = FakeMem::default();
        assert_eq!(run(&image, 0x180000000, &mem), None);
    }

    #[test]
    fn returns_none_when_prologue_opcode_mismatches() {
        let mut image = build_image(0x900);
        // Corrupt the first opcode byte at FN_RVA.
        image[FN_RVA as usize] = 0xcc;
        let mem = FakeMem::default();
        assert_eq!(run(&image, 0x180000000, &mem), None);
    }

    #[test]
    fn returns_none_when_prologue_truncated() {
        let mut image = build_image(0x900);
        // Truncate the image so FN_RVA + 8 lies past the end.
        image.truncate(FN_RVA as usize + 4);
        let mem = FakeMem::default();
        assert_eq!(run(&image, 0x180000000, &mem), None);
    }

    #[test]
    fn returns_none_when_static_pointer_unreadable() {
        let image = build_image(0x900);
        // FakeMem has no entry for the static-pointer address.
        let mem = FakeMem::default();
        assert_eq!(run(&image, 0x180000000, &mem), None);
    }

    #[test]
    fn returns_none_when_static_pointer_is_null() {
        // The static slot is mapped but contains 0 — Mono initialized
        // the symbol but not yet the domain. Walker reports None.
        let static_ptr_rva: u32 = 0x900;
        let image = build_image(static_ptr_rva);
        let base: u64 = 0x180000000;
        let static_ptr_addr = base + static_ptr_rva as u64;

        let mut mem = FakeMem::default();
        mem.add(static_ptr_addr, vec![0u8; 8]);
        assert_eq!(run(&image, base, &mem), None);
    }

    #[test]
    fn handles_negative_displacement_in_prologue() -> Result<(), String> {
        // Static pointer placed *before* the function — disp32 is
        // negative. Real builds typically use positive disp, but the
        // composite must handle either.
        let static_ptr_rva: u32 = 0x100; // before FN_RVA = 0x800
        let image = build_image(static_ptr_rva);
        let base: u64 = 0x180000000;
        let static_ptr_addr = base + static_ptr_rva as u64;
        let domain_addr: u64 = 0xdead_cafe_babe_0010;

        let mut mem = FakeMem::default();
        mem.add(static_ptr_addr, domain_addr.to_le_bytes().to_vec());

        let domain = run(&image, base, &mem).ok_or("negative disp must resolve")?;
        assert_eq!(domain, domain_addr);
        Ok(())
    }

    /// Real RVA of `mono_root_domain` static slot in MTGA build
    /// `Fri Apr 11 17:22:20 2025`. Documented here so a future reader
    /// of this fixture can correlate it back to the disassembly recipe
    /// in the `mono-memory-reader` skill.
    #[allow(dead_code)]
    const MTGA_REAL_STATIC_PTR_RVA: u32 = 0x746020;

    #[test]
    fn realistic_high_base_address() -> Result<(), String> {
        // MTGA's mono DLL ImageBase is 0x180000000; verify the
        // composite produces the same answer at a high base. The
        // build_image fixture caps at 0x2000 so we test with a
        // smaller RVA — see MTGA_REAL_STATIC_PTR_RVA above for the
        // production value.
        let small_static: u32 = 0x900;
        let image = build_image(small_static);
        let base: u64 = 0x1_8000_0000;
        let static_ptr_addr = base + small_static as u64;
        let domain_addr: u64 = 0x7fff_aabb_ccdd_0000;

        let mut mem = FakeMem::default();
        mem.add(static_ptr_addr, domain_addr.to_le_bytes().to_vec());

        let domain = run(&image, base, &mem).ok_or("high base must resolve")?;
        assert_eq!(domain, domain_addr);
        Ok(())
    }
}
