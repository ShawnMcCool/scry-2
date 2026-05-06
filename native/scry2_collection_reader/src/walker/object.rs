//! Object-level walker primitives.
//!
//! Two helpers shared by every chain module — until this module
//! existed, both were re-implemented in `chain`, `boosters`,
//! `match_info`, and `match_scene` (audit findings 1.1 and 1.2):
//!
//! - [`read_runtime_class_bytes`] — given an object pointer, follow
//!   `obj.vtable.klass` and read a `MonoClassDef`-sized blob for the
//!   instance's runtime class.
//! - [`read_instance_pointer`] — resolve a named field on a class,
//!   reject static/negative-offset fields, then read an 8-byte
//!   pointer at `object_addr + field.offset`.
//!
//! Both functions take a `read_mem` closure so the same code drives
//! live `process_vm_readv` reads in production and `FakeMem` stubs
//! in tests.

use super::field::{self, ResolvedField};
use super::mono::{self, MonoOffsets, CLASS_DEF_BLOB_LEN};

/// Read `obj.vtable.klass` and pull a `MonoClassDef`-sized blob for
/// the instance's runtime class.
///
/// `MonoObject.vtable` and `MonoVTable.klass` both live at offset 0
/// of their respective structs — no [`MonoOffsets`] entry needed.
///
/// Returns `None` on any read failure or null pointer in the chain.
pub fn read_runtime_class_bytes<F>(obj_addr: u64, read_mem: &F) -> Option<Vec<u8>>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let vtable_addr = read_mem(obj_addr, 8).and_then(|b| mono::read_u64(&b, 0, 0))?;
    if vtable_addr == 0 {
        return None;
    }
    let klass_addr = read_mem(vtable_addr, 8).and_then(|b| mono::read_u64(&b, 0, 0))?;
    if klass_addr == 0 {
        return None;
    }
    read_mem(klass_addr, CLASS_DEF_BLOB_LEN)
}

/// Resolve `field_name` on the class at `class_bytes`, then read a
/// pointer at `object_addr + field.offset`.
///
/// Rejects static fields, negative offsets, and null pointers — those
/// indicate the walker is on a wrong path or hit an uninitialised
/// field. Returns `None` for any of those conditions.
pub fn read_instance_pointer<F>(
    offsets: &MonoOffsets,
    class_bytes: &[u8],
    object_addr: u64,
    field_name: &str,
    read_mem: &F,
) -> Option<u64>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let resolved: ResolvedField =
        field::find_field_by_name(offsets, class_bytes, field_name, read_mem)?;
    if resolved.is_static || resolved.offset < 0 {
        return None;
    }
    let addr = object_addr.checked_add(resolved.offset as u64)?;
    let bytes = read_mem(addr, 8)?;
    let ptr = mono::read_u64(&bytes, 0, 0)?;
    if ptr == 0 {
        None
    } else {
        Some(ptr)
    }
}

/// Like [`read_instance_pointer`] but resolves `field_name` against
/// the class's parent chain — necessary for inherited backing fields
/// (e.g. `LimitedPlayerEvent` inherits `<EventInfo>k__BackingField`
/// from `BasicPlayerEvent`).
///
/// Same null/static/negative-offset rejection rules as
/// [`read_instance_pointer`].
pub fn read_instance_pointer_in_chain<F>(
    offsets: &MonoOffsets,
    class_bytes: &[u8],
    object_addr: u64,
    field_name: &str,
    read_mem: &F,
) -> Option<u64>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let resolved: ResolvedField =
        field::find_field_by_name_in_chain(offsets, class_bytes, field_name, *read_mem)?;
    if resolved.is_static || resolved.offset < 0 {
        return None;
    }
    let addr = object_addr.checked_add(resolved.offset as u64)?;
    let bytes = read_mem(addr, 8)?;
    let ptr = mono::read_u64(&bytes, 0, 0)?;
    if ptr == 0 {
        None
    } else {
        Some(ptr)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::walker::mono::MONO_CLASS_FIELD_SIZE;
    use crate::walker::test_support::{make_class_def, make_field_entry, make_type_block, FakeMem};

    #[test]
    fn read_runtime_class_bytes_resolves_via_vtable() -> Result<(), String> {
        let mut mem = FakeMem::default();
        let object_addr: u64 = 0x10_0000;
        let vtable_addr: u64 = 0x20_0000;
        let class_addr: u64 = 0x30_0000;

        let mut object = vec![0u8; 0x20];
        object[0..8].copy_from_slice(&vtable_addr.to_le_bytes());
        mem.add(object_addr, object);

        let mut vt = vec![0u8; 0x10];
        vt[0..8].copy_from_slice(&class_addr.to_le_bytes());
        mem.add(vtable_addr, vt);

        let class = make_class_def(0xdead_0000, 0);
        mem.add(class_addr, class.clone());

        let got =
            read_runtime_class_bytes(object_addr, &|a, l| mem.read(a, l)).ok_or("must resolve")?;
        assert_eq!(got, class);
        Ok(())
    }

    #[test]
    fn read_runtime_class_bytes_returns_none_on_null_vtable() {
        let mut mem = FakeMem::default();
        let object_addr: u64 = 0x10_0000;
        mem.add(object_addr, vec![0u8; 0x20]);
        assert_eq!(
            read_runtime_class_bytes(object_addr, &|a, l| mem.read(a, l)),
            None
        );
    }

    #[test]
    fn read_instance_pointer_resolves_named_field() -> Result<(), String> {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();

        let fields_addr: u64 = 0x10_0000;
        let name_addr: u64 = 0x20_0000;
        let type_addr: u64 = 0x30_0000;

        mem.add(fields_addr, make_field_entry(name_addr, type_addr, 0, 0x18));
        mem.add(name_addr, {
            let mut v = b"_field".to_vec();
            v.push(0);
            v
        });
        mem.add(type_addr, make_type_block(0));
        let class = make_class_def(fields_addr, 1);

        let object_addr: u64 = 0x40_0000;
        let target_ptr: u64 = 0xcafe_babe_0000_0000;
        let mut object = vec![0u8; 0x40];
        object[0x18..0x20].copy_from_slice(&target_ptr.to_le_bytes());
        mem.add(object_addr, object);

        let got = read_instance_pointer(&offsets, &class, object_addr, "_field", &|a, l| {
            mem.read(a, l)
        })
        .ok_or("must resolve")?;
        assert_eq!(got, target_ptr);
        Ok(())
    }

    #[test]
    fn read_instance_pointer_rejects_static_field() {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();

        let fields_addr: u64 = 0x10_0000;
        let name_addr: u64 = 0x20_0000;
        let type_addr: u64 = 0x30_0000;

        mem.add(fields_addr, make_field_entry(name_addr, type_addr, 0, 0x10));
        mem.add(name_addr, {
            let mut v = b"_static".to_vec();
            v.push(0);
            v
        });
        mem.add(type_addr, make_type_block(mono::MONO_FIELD_ATTR_STATIC));
        let class = make_class_def(fields_addr, 1);

        let object_addr: u64 = 0x40_0000;
        mem.add(object_addr, vec![0u8; 0x40]);

        assert_eq!(
            read_instance_pointer(&offsets, &class, object_addr, "_static", &|a, l| {
                mem.read(a, l)
            }),
            None,
            "static fields must be rejected for instance reads"
        );
    }

    #[test]
    fn read_instance_pointer_returns_none_for_null_target() {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let fields_addr: u64 = 0x10_0000;
        let name_addr: u64 = 0x20_0000;
        let type_addr: u64 = 0x30_0000;

        mem.add(fields_addr, make_field_entry(name_addr, type_addr, 0, 0x10));
        mem.add(name_addr, {
            let mut v = b"x".to_vec();
            v.push(0);
            v
        });
        mem.add(type_addr, make_type_block(0));
        let class = make_class_def(fields_addr, 1);

        let object_addr: u64 = 0x40_0000;
        mem.add(object_addr, vec![0u8; 0x40]); // slot left as null

        assert_eq!(
            read_instance_pointer(&offsets, &class, object_addr, "x", &|a, l| {
                mem.read(a, l)
            }),
            None
        );
    }

    // Silence unused-import warning when the test module imports
    // MONO_CLASS_FIELD_SIZE for documentation but doesn't need it.
    #[allow(dead_code)]
    const _SIZE: usize = MONO_CLASS_FIELD_SIZE;
}
