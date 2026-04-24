//! Parse the zero-argument accessor prologue that Mono uses for
//! getters like `mono_get_root_domain`.
//!
//! On x86-64 the entire function body is:
//!
//! ```text
//!   48 8b 05 disp32    ; mov  rax, [rip + disp32]
//!   c3                 ; ret
//! ```
//!
//! — eight bytes total. The RIP-relative displacement, when added to
//! the address of the instruction *following* the `mov`, points at the
//! static pointer variable the accessor reads. For
//! `mono_get_root_domain` that variable is the singleton `MonoDomain *`
//! created at runtime startup.
//!
//! This module turns the eight-byte body plus the function's absolute
//! address into the absolute address of the static pointer. It does
//! not read memory — the caller supplies the bytes.

/// Length of the mov+ret prologue: 3-byte opcode + 4-byte disp32 +
/// 1-byte `ret`.
pub const PROLOGUE_LEN: usize = 8;

/// Offset from the start of the function at which RIP points once the
/// `mov` has been decoded — 3-byte opcode + 4-byte displacement.
const RIP_AFTER_MOV: u64 = 7;

/// Parse the `mov rax, [rip+disp32]; ret` prologue at `bytes` (whose
/// first byte lives at `fn_addr` in the target process) and return the
/// absolute address of the static pointer the accessor reads.
///
/// Returns `None` if `bytes` is too short, the opcode does not match,
/// or the displacement arithmetic would wrap the address space.
pub fn parse_mov_rax_rip_ret(bytes: &[u8], fn_addr: u64) -> Option<u64> {
    if bytes.len() < PROLOGUE_LEN {
        return None;
    }

    // REX.W (0x48) + MOV r64, r/m64 (0x8b) + ModRM 0x05 (rax, [rip+disp32]).
    if bytes[0] != 0x48 || bytes[1] != 0x8b || bytes[2] != 0x05 {
        return None;
    }
    if bytes[7] != 0xc3 {
        return None;
    }

    let disp = i32::from_le_bytes([bytes[3], bytes[4], bytes[5], bytes[6]]) as i64;
    let rip_after_mov = fn_addr.checked_add(RIP_AFTER_MOV)?;

    if disp >= 0 {
        rip_after_mov.checked_add(disp as u64)
    } else {
        rip_after_mov.checked_sub(disp.unsigned_abs())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolves_positive_displacement() {
        // fn_addr = 0x1000, disp = 0x100 (LE: 00 01 00 00)
        // expected = 0x1000 + 7 + 0x100 = 0x1107
        let bytes = [0x48, 0x8b, 0x05, 0x00, 0x01, 0x00, 0x00, 0xc3];
        assert_eq!(parse_mov_rax_rip_ret(&bytes, 0x1000), Some(0x1107));
    }

    #[test]
    fn resolves_negative_displacement() {
        // disp = -0x10 → LE two's-complement: f0 ff ff ff
        // fn_addr = 0x1000, expected = 0x1000 + 7 - 0x10 = 0xFF7
        let bytes = [0x48, 0x8b, 0x05, 0xf0, 0xff, 0xff, 0xff, 0xc3];
        assert_eq!(parse_mov_rax_rip_ret(&bytes, 0x1000), Some(0xFF7));
    }

    #[test]
    fn resolves_zero_displacement() {
        // disp = 0 — pointer variable lives right after the function.
        let bytes = [0x48, 0x8b, 0x05, 0x00, 0x00, 0x00, 0x00, 0xc3];
        assert_eq!(parse_mov_rax_rip_ret(&bytes, 0x2000), Some(0x2007));
    }

    #[test]
    fn realistic_high_address() {
        // High-canonical address typical of ASLR'd loaded modules.
        // fn_addr = 0x7f_1234_5000, disp = 0x1000
        // expected = 0x7f_1234_5000 + 7 + 0x1000 = 0x7f_1234_6007
        let bytes = [0x48, 0x8b, 0x05, 0x00, 0x10, 0x00, 0x00, 0xc3];
        assert_eq!(
            parse_mov_rax_rip_ret(&bytes, 0x7f_1234_5000),
            Some(0x7f_1234_6007)
        );
    }

    #[test]
    fn rejects_wrong_rex_prefix() {
        let bytes = [0x49, 0x8b, 0x05, 0x00, 0x00, 0x00, 0x00, 0xc3];
        assert_eq!(parse_mov_rax_rip_ret(&bytes, 0x1000), None);
    }

    #[test]
    fn rejects_wrong_mov_opcode() {
        let bytes = [0x48, 0x89, 0x05, 0x00, 0x00, 0x00, 0x00, 0xc3];
        assert_eq!(parse_mov_rax_rip_ret(&bytes, 0x1000), None);
    }

    #[test]
    fn rejects_wrong_modrm_byte() {
        let bytes = [0x48, 0x8b, 0x00, 0x00, 0x00, 0x00, 0x00, 0xc3];
        assert_eq!(parse_mov_rax_rip_ret(&bytes, 0x1000), None);
    }

    #[test]
    fn rejects_missing_ret() {
        // trailing byte is NOP (0x90), not RET (0xc3).
        let bytes = [0x48, 0x8b, 0x05, 0x00, 0x00, 0x00, 0x00, 0x90];
        assert_eq!(parse_mov_rax_rip_ret(&bytes, 0x1000), None);
    }

    #[test]
    fn rejects_too_few_bytes() {
        let bytes = [0x48, 0x8b, 0x05];
        assert_eq!(parse_mov_rax_rip_ret(&bytes, 0x1000), None);
    }

    #[test]
    fn rejects_empty_slice() {
        assert_eq!(parse_mov_rax_rip_ret(&[], 0x1000), None);
    }

    #[test]
    fn accepts_trailing_bytes_after_prologue() {
        // Real disassembly may have padding or the next function after
        // the ret; we only look at the first 8 bytes.
        let bytes = [
            0x48, 0x8b, 0x05, 0x00, 0x00, 0x00, 0x00, 0xc3, 0x90, 0x90, 0x90,
        ];
        assert_eq!(parse_mov_rax_rip_ret(&bytes, 0x1000), Some(0x1007));
    }

    #[test]
    fn refuses_to_wrap_low() {
        // Small fn_addr with a very negative displacement would
        // underflow u64 — must return None instead of panicking.
        let bytes = [0x48, 0x8b, 0x05, 0x00, 0x00, 0x00, 0x80, 0xc3];
        // disp = 0x80000000 as i32 = -2_147_483_648; fn_addr = 0 → underflow.
        assert_eq!(parse_mov_rax_rip_ret(&bytes, 0), None);
    }

    #[test]
    fn refuses_to_wrap_high() {
        // fn_addr near u64::MAX + positive displacement overflows.
        let bytes = [0x48, 0x8b, 0x05, 0xff, 0xff, 0xff, 0x7f, 0xc3];
        // disp = i32::MAX = 0x7fff_ffff
        assert_eq!(parse_mov_rax_rip_ret(&bytes, u64::MAX - 3), None);
    }
}
