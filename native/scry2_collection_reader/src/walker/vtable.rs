//! Resolve a `MonoVTable *` for a `MonoClass` in a given
//! `MonoDomain`, and — from that — the static-storage base pointer
//! used for reading static fields.
//!
//! Static fields in mono live at `vtable->vtable[vtable_size]`, i.e.
//! in a slot appended just past the end of the method trampoline
//! array. Reading a static field means:
//!
//! ```text
//! vtable  = class.runtime_info.domain_vtables[domain.domain_id]
//! data    = *(vtable + 0x48 + class.vtable_size * 8)
//! value   = *(data + field.offset)
//! ```
//!
//! This module covers the first two lines. Callers (see
//! `walker/chain.rs`) add the third.

use super::limits::MAX_DOMAINS;
use super::mono::{self, MonoOffsets};

/// Resolve the `MonoVTable *` for `class_addr` in domain
/// `domain_addr`. Returns `None` on any read failure, out-of-range
/// `domain_id`, or null slot.
pub fn class_vtable<F>(
    offsets: &MonoOffsets,
    class_addr: u64,
    domain_addr: u64,
    read_mem: F,
) -> Option<u64>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    // Read MonoClass — enough to cover `runtime_info` at 0xd0.
    let class_buf = read_mem(class_addr, offsets.class_runtime_info + 8)?;
    let rti_addr = mono::class_runtime_info_ptr(offsets, &class_buf, 0)?;
    if rti_addr == 0 {
        return None;
    }

    // Read MonoDomain — enough to cover `domain_id` at 0x94.
    let domain_buf = read_mem(domain_addr, offsets.domain_id + 4)?;
    let did = mono::domain_id(offsets, &domain_buf, 0)?;
    if did < 0 {
        return None;
    }
    let did = did as u32;

    // Read MonoClassRuntimeInfo's max_domain, bounds-check, then read
    // the specific domain_vtables slot. Two small reads — avoids
    // allocating a buffer that scales with domain count.
    let max_domain_buf = read_mem(rti_addr, offsets.runtime_info_max_domain + 2)?;
    let max_domain = mono::runtime_info_max_domain(offsets, &max_domain_buf, 0)?;
    if max_domain > MAX_DOMAINS {
        return None;
    }
    if did > max_domain as u32 {
        return None;
    }

    let slot_addr = mono::runtime_info_domain_vtable_addr(offsets, rti_addr, did)?;
    let slot_buf = read_mem(slot_addr, 8)?;
    let vtable_addr = mono::read_u64(&slot_buf, 0, 0)?;
    if vtable_addr == 0 {
        return None;
    }
    Some(vtable_addr)
}

/// Resolve the static-storage base pointer for `class_addr` in
/// `domain_addr`. Equivalent to mono's
/// `mono_vtable_get_static_field_data(vtable)` when `has_static_fields`
/// is set.
///
/// Reads `MonoClass.vtable_size`, walks past the flex method-slot
/// array, and dereferences the trailing pointer. Returns `None` if
/// the class has no static storage (the trailing pointer is `NULL`).
pub fn static_storage_base<F>(
    offsets: &MonoOffsets,
    class_addr: u64,
    domain_addr: u64,
    read_mem: F,
) -> Option<u64>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let vtable_addr = class_vtable(offsets, class_addr, domain_addr, &read_mem)?;

    // Need MonoClass.vtable_size (u32 at 0x5c). We already fetched
    // enough class bytes inside `class_vtable`, but that buffer is
    // gone — re-read just the slice we need.
    let class_buf = read_mem(class_addr, offsets.class_vtable_size + 4)?;
    let vtsize = mono::class_vtable_size(offsets, &class_buf, 0)?;
    if vtsize < 0 {
        return None;
    }

    let static_slot_addr = mono::vtable_static_slot_addr(offsets, vtable_addr, vtsize as u32)?;
    let slot_buf = read_mem(static_slot_addr, 8)?;
    let storage = mono::read_u64(&slot_buf, 0, 0)?;
    if storage == 0 {
        return None;
    }
    Some(storage)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::walker::test_support::FakeMem;

    /// Build a MonoClass blob large enough to cover runtime_info @0xd0
    /// and vtable_size @0x5c.
    fn make_class(runtime_info_ptr: u64, vtable_size: i32) -> Vec<u8> {
        let o = MonoOffsets::mtga_default();
        let mut buf = vec![0u8; mono::CLASS_DEF_BLOB_LEN];
        buf[o.class_runtime_info..o.class_runtime_info + 8]
            .copy_from_slice(&runtime_info_ptr.to_le_bytes());
        buf[o.class_vtable_size..o.class_vtable_size + 4]
            .copy_from_slice(&(vtable_size as u32).to_le_bytes());
        buf
    }

    /// Build a MonoDomain blob with domain_id at 0x94.
    fn make_domain(domain_id: i32) -> Vec<u8> {
        let o = MonoOffsets::mtga_default();
        let mut buf = vec![0u8; 0x100];
        buf[o.domain_id..o.domain_id + 4].copy_from_slice(&(domain_id as u32).to_le_bytes());
        buf
    }

    /// Build a MonoClassRuntimeInfo blob: max_domain + domain_vtables[N].
    fn make_runtime_info(max_domain: u16, domain_vtables: &[u64]) -> Vec<u8> {
        let o = MonoOffsets::mtga_default();
        let size = o.runtime_info_domain_vtables + domain_vtables.len() * 8;
        let mut buf = vec![0u8; size];
        buf[o.runtime_info_max_domain..o.runtime_info_max_domain + 2]
            .copy_from_slice(&max_domain.to_le_bytes());
        for (i, vt) in domain_vtables.iter().enumerate() {
            let slot = o.runtime_info_domain_vtables + i * 8;
            buf[slot..slot + 8].copy_from_slice(&vt.to_le_bytes());
        }
        buf
    }

    /// Build a MonoVTable blob large enough to cover the static-storage
    /// slot for a class with the given `vtable_size`. Writes the
    /// static-storage pointer into the trailing slot.
    fn make_vtable(vtable_size: u32, static_storage: u64) -> Vec<u8> {
        let o = MonoOffsets::mtga_default();
        let slot_off = o.vtable_method_slots + (vtable_size as usize) * 8;
        let mut buf = vec![0u8; slot_off + 8];
        buf[slot_off..slot_off + 8].copy_from_slice(&static_storage.to_le_bytes());
        buf
    }

    #[test]
    fn class_vtable_resolves_fast_path() -> Result<(), String> {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();

        let class_addr: u64 = 0x1000;
        let domain_addr: u64 = 0x2000;
        let rti_addr: u64 = 0x3000;
        let vtable_addr: u64 = 0x4000;

        mem.add(class_addr, make_class(rti_addr, /*vtable_size*/ 3));
        mem.add(domain_addr, make_domain(0));
        // max_domain=0, one vtable slot pointing at our vtable.
        mem.add(rti_addr, make_runtime_info(0, &[vtable_addr]));

        let got = class_vtable(&offsets, class_addr, domain_addr, |a, l| mem.read(a, l))
            .ok_or("fast path should resolve")?;
        assert_eq!(got, vtable_addr);
        Ok(())
    }

    #[test]
    fn class_vtable_returns_none_when_domain_id_exceeds_max_domain() {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let class_addr: u64 = 0x1000;
        let domain_addr: u64 = 0x2000;
        let rti_addr: u64 = 0x3000;

        mem.add(class_addr, make_class(rti_addr, 0));
        // domain_id = 5, max_domain = 2 → out of range
        mem.add(domain_addr, make_domain(5));
        mem.add(rti_addr, make_runtime_info(2, &[0x4000, 0x5000, 0x6000]));

        assert_eq!(
            class_vtable(&offsets, class_addr, domain_addr, |a, l| mem.read(a, l)),
            None
        );
    }

    #[test]
    fn class_vtable_returns_none_when_runtime_info_is_null() {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let class_addr: u64 = 0x1000;
        let domain_addr: u64 = 0x2000;

        mem.add(class_addr, make_class(0, 0)); // runtime_info = NULL
        mem.add(domain_addr, make_domain(0));

        assert_eq!(
            class_vtable(&offsets, class_addr, domain_addr, |a, l| mem.read(a, l)),
            None
        );
    }

    #[test]
    fn class_vtable_returns_none_for_negative_domain_id() {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let class_addr: u64 = 0x1000;
        let domain_addr: u64 = 0x2000;
        let rti_addr: u64 = 0x3000;

        mem.add(class_addr, make_class(rti_addr, 0));
        mem.add(domain_addr, make_domain(-1)); // invalid
        mem.add(rti_addr, make_runtime_info(0, &[0x4000]));

        assert_eq!(
            class_vtable(&offsets, class_addr, domain_addr, |a, l| mem.read(a, l)),
            None
        );
    }

    #[test]
    fn class_vtable_returns_none_when_slot_is_null() {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let class_addr: u64 = 0x1000;
        let domain_addr: u64 = 0x2000;
        let rti_addr: u64 = 0x3000;

        mem.add(class_addr, make_class(rti_addr, 0));
        mem.add(domain_addr, make_domain(0));
        mem.add(rti_addr, make_runtime_info(0, &[0])); // vtable pointer NULL

        assert_eq!(
            class_vtable(&offsets, class_addr, domain_addr, |a, l| mem.read(a, l)),
            None
        );
    }

    #[test]
    fn class_vtable_rejects_absurdly_large_max_domain() {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let class_addr: u64 = 0x1000;
        let domain_addr: u64 = 0x2000;
        let rti_addr: u64 = 0x3000;

        mem.add(class_addr, make_class(rti_addr, 0));
        mem.add(domain_addr, make_domain(0));
        // max_domain = 9999 > MAX_DOMAINS guard; heuristic: corrupt data.
        mem.add(rti_addr, {
            let mut v = vec![0u8; 16];
            v[0..2].copy_from_slice(&9999u16.to_le_bytes());
            v[8..16].copy_from_slice(&0x4000u64.to_le_bytes());
            v
        });

        assert_eq!(
            class_vtable(&offsets, class_addr, domain_addr, |a, l| mem.read(a, l)),
            None
        );
    }

    #[test]
    fn class_vtable_picks_correct_slot_for_nonzero_domain_id() -> Result<(), String> {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let class_addr: u64 = 0x1000;
        let domain_addr: u64 = 0x2000;
        let rti_addr: u64 = 0x3000;

        mem.add(class_addr, make_class(rti_addr, 0));
        mem.add(domain_addr, make_domain(2));
        mem.add(rti_addr, make_runtime_info(2, &[0x4000, 0x5000, 0x6000]));

        let got = class_vtable(&offsets, class_addr, domain_addr, |a, l| mem.read(a, l))
            .ok_or("should find slot 2")?;
        assert_eq!(got, 0x6000);
        Ok(())
    }

    #[test]
    fn static_storage_base_reads_trailing_slot() -> Result<(), String> {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let class_addr: u64 = 0x1000;
        let domain_addr: u64 = 0x2000;
        let rti_addr: u64 = 0x3000;
        let vtable_addr: u64 = 0x4000;
        let storage: u64 = 0x7777_0000;
        let vtable_size: i32 = 4;

        mem.add(class_addr, make_class(rti_addr, vtable_size));
        mem.add(domain_addr, make_domain(0));
        mem.add(rti_addr, make_runtime_info(0, &[vtable_addr]));
        mem.add(vtable_addr, make_vtable(vtable_size as u32, storage));

        let got = static_storage_base(&offsets, class_addr, domain_addr, |a, l| mem.read(a, l))
            .ok_or("static storage should resolve")?;
        assert_eq!(got, storage);
        Ok(())
    }

    #[test]
    fn static_storage_base_returns_none_for_null_storage() {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let class_addr: u64 = 0x1000;
        let domain_addr: u64 = 0x2000;
        let rti_addr: u64 = 0x3000;
        let vtable_addr: u64 = 0x4000;

        mem.add(class_addr, make_class(rti_addr, 2));
        mem.add(domain_addr, make_domain(0));
        mem.add(rti_addr, make_runtime_info(0, &[vtable_addr]));
        mem.add(vtable_addr, make_vtable(2, 0)); // storage NULL

        assert_eq!(
            static_storage_base(&offsets, class_addr, domain_addr, |a, l| mem.read(a, l)),
            None
        );
    }

    #[test]
    fn static_storage_base_uses_class_vtable_size() -> Result<(), String> {
        // Confirm the offset arithmetic picks up the slot at
        // `vtable + 0x48 + vtable_size*8` — not a fixed location.
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let class_addr: u64 = 0x1000;
        let domain_addr: u64 = 0x2000;
        let rti_addr: u64 = 0x3000;
        let vtable_addr: u64 = 0x4000;

        // Two classes with DIFFERENT vtable_size values should read
        // DIFFERENT slots of the vtable blob. Build a vtable blob
        // large enough that each vtable_size selects a distinct
        // storage pointer value so we can tell them apart.
        let vtable_size: i32 = 10;
        let unique_storage: u64 = 0x9999_abcd;

        mem.add(class_addr, make_class(rti_addr, vtable_size));
        mem.add(domain_addr, make_domain(0));
        mem.add(rti_addr, make_runtime_info(0, &[vtable_addr]));
        mem.add(vtable_addr, make_vtable(vtable_size as u32, unique_storage));

        let got = static_storage_base(&offsets, class_addr, domain_addr, |a, l| mem.read(a, l))
            .ok_or("should resolve")?;
        assert_eq!(got, unique_storage);
        Ok(())
    }
}
