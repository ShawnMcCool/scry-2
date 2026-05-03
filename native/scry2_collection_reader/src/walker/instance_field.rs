//! Typed `read_instance_<type>` helpers for instance-field reads.
//!
//! Until this module existed, the same prelude — resolve the field by
//! name, reject statics and negative offsets, compute `object_addr +
//! offset`, read N bytes — was open-coded once per type in
//! `match_info`, `inventory`, `list_t`, and `boosters` (audit
//! finding 2.2). The eight helpers consolidated here all share the
//! same prelude via [`resolve_field_addr`] and differ only in:
//! - bytes to read (1 / 4 / 8),
//! - decoder (`u8 → bool`, `u32`, `u64 → f64`, `u64 → ptr` chase),
//! - what to do on a null pointer (string returns `Some(String::new())`
//!   for an empty string; pointer-list returns `Some(vec![])`).
//!
//! All helpers return `Option`. `None` means the read hit a structural
//! problem — class lacks the field, field is static, address overflows,
//! the byte read failed, or the value's runtime class is unreadable.
//! Helpers do **not** silently fall back to defaults like `0` or
//! `false` (audit finding 1.3) — the caller decides how to coalesce.
//!
//! All functions take a `read_mem` closure so the same code drives
//! live `process_vm_readv` reads in production and `FakeMem` stubs
//! in tests.

use super::field::{self, ResolvedField};
use super::mono::{self, MonoOffsets};
use super::mono_array;
use super::object;

/// Common prelude: resolve `field_name` against the class, validate
/// it's an instance field with a non-negative offset, and return the
/// remote address `object_addr + field.offset`.
///
/// Returns `None` if the field cannot be resolved, is static, has a
/// negative offset, or the address overflows.
fn resolve_field_addr<F>(
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
    object_addr.checked_add(resolved.offset as u64)
}

/// Parent-aware variant — walks `MonoClass.parent` when the field is
/// not declared on the runtime class. See
/// [`field::find_field_by_name_in_chain`] for the chain-walk
/// semantics.
fn resolve_field_addr_in_chain<F>(
    offsets: &MonoOffsets,
    class_bytes: &[u8],
    object_addr: u64,
    field_name: &str,
    read_mem: F,
) -> Option<u64>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let resolved: ResolvedField =
        field::find_field_by_name_in_chain(offsets, class_bytes, field_name, read_mem)?;
    if resolved.is_static || resolved.offset < 0 {
        return None;
    }
    object_addr.checked_add(resolved.offset as u64)
}

/// Parent-aware variant of [`read_instance_i32`]. Used when the
/// declared field may live on a base class (e.g. `BaseGrpId` on a
/// `CardInstanceData` parent).
pub fn read_instance_i32_in_chain<F>(
    offsets: &MonoOffsets,
    class_bytes: &[u8],
    object_addr: u64,
    field_name: &str,
    read_mem: &F,
) -> Option<i32>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let addr =
        resolve_field_addr_in_chain(offsets, class_bytes, object_addr, field_name, *read_mem)?;
    let bytes = read_mem(addr, 4)?;
    mono::read_u32(&bytes, 0, 0).map(|v| v as i32)
}

/// Read a 4-byte signed integer instance field.
pub fn read_instance_i32<F>(
    offsets: &MonoOffsets,
    class_bytes: &[u8],
    object_addr: u64,
    field_name: &str,
    read_mem: &F,
) -> Option<i32>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let addr = resolve_field_addr(offsets, class_bytes, object_addr, field_name, read_mem)?;
    let bytes = read_mem(addr, 4)?;
    mono::read_u32(&bytes, 0, 0).map(|v| v as i32)
}

/// Read an 8-byte unsigned integer instance field.
pub fn read_instance_u64<F>(
    offsets: &MonoOffsets,
    class_bytes: &[u8],
    object_addr: u64,
    field_name: &str,
    read_mem: &F,
) -> Option<u64>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let addr = resolve_field_addr(offsets, class_bytes, object_addr, field_name, read_mem)?;
    let bytes = read_mem(addr, 8)?;
    mono::read_u64(&bytes, 0, 0)
}

/// Read a 1-byte boolean instance field. Mono encodes `bool` as a
/// single byte; nonzero is `true`.
pub fn read_instance_bool<F>(
    offsets: &MonoOffsets,
    class_bytes: &[u8],
    object_addr: u64,
    field_name: &str,
    read_mem: &F,
) -> Option<bool>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let addr = resolve_field_addr(offsets, class_bytes, object_addr, field_name, read_mem)?;
    let bytes = read_mem(addr, 1)?;
    bytes.first().map(|b| *b != 0)
}

/// Read an 8-byte IEEE-754 double instance field.
pub fn read_instance_f64<F>(
    offsets: &MonoOffsets,
    class_bytes: &[u8],
    object_addr: u64,
    field_name: &str,
    read_mem: &F,
) -> Option<f64>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let addr = resolve_field_addr(offsets, class_bytes, object_addr, field_name, read_mem)?;
    let bytes = read_mem(addr, 8)?;
    mono::read_u64(&bytes, 0, 0).map(f64::from_bits)
}

/// Read a `MonoString *` instance field and decode its UTF-16 contents
/// using [`mono::read_mono_string`].
///
/// `max_chars` caps the length to guard against torn reads.
/// Returns `None` if the field doesn't resolve, the slot is null, or
/// the string is unreadable. Returns `Some("")` for a valid empty
/// string.
pub fn read_instance_string<F>(
    offsets: &MonoOffsets,
    class_bytes: &[u8],
    object_addr: u64,
    field_name: &str,
    max_chars: usize,
    read_mem: &F,
) -> Option<String>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let addr = resolve_field_addr(offsets, class_bytes, object_addr, field_name, read_mem)?;
    let str_ptr = read_mem(addr, 8).and_then(|b| mono::read_u64(&b, 0, 0))?;
    mono::read_mono_string(str_ptr, max_chars, read_mem)
}

/// Read a `List<int>` instance field. Resolves the field, dereferences
/// the list pointer, looks up its runtime class, then reads `_size`
/// and bulk-reads the items array.
///
/// Returns `None` only when the field itself can't be resolved.
/// Returns `Some(vec![])` for null lists, empty lists, or any state
/// where the read hits a benign dead end (the field exists but the
/// list is empty / stale).
pub fn read_instance_int_list<F>(
    offsets: &MonoOffsets,
    class_bytes: &[u8],
    object_addr: u64,
    field_name: &str,
    max_elements: usize,
    read_mem: &F,
) -> Option<Vec<i32>>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let addr = resolve_field_addr(offsets, class_bytes, object_addr, field_name, read_mem)?;
    let Some(list_ptr) = read_mem(addr, 8).and_then(|b| mono::read_u64(&b, 0, 0)) else {
        return Some(Vec::new());
    };
    if list_ptr == 0 {
        return Some(Vec::new());
    }
    let Some(list_class_bytes) = object::read_runtime_class_bytes(list_ptr, read_mem) else {
        return Some(Vec::new());
    };
    let Some(items_ptr) =
        object::read_instance_pointer(offsets, &list_class_bytes, list_ptr, "_items", read_mem)
    else {
        return Some(Vec::new());
    };
    let size =
        read_instance_i32(offsets, &list_class_bytes, list_ptr, "_size", read_mem).unwrap_or(0);
    if size <= 0 {
        return Some(Vec::new());
    }
    let count = (size as usize).min(max_elements);
    let Some(blob) =
        mono_array::read_array_elements(items_ptr, MONO_ARRAY_VECTOR_OFFSET, count, 4, read_mem)
    else {
        return Some(Vec::new());
    };
    Some(
        blob.chunks_exact(4)
            .map(|c| i32::from_le_bytes([c[0], c[1], c[2], c[3]]))
            .collect(),
    )
}

/// `MonoArray<T>` element storage starts at `array_addr + 0x20`.
/// Mirrors `list_t::MONO_ARRAY_VECTOR_OFFSET`.
const MONO_ARRAY_VECTOR_OFFSET: u64 = 0x20;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::walker::mono::MONO_CLASS_FIELD_SIZE;
    use crate::walker::test_support::{make_class_def, make_field_entry, make_type_block, FakeMem};

    /// Install a class with one named instance field at `offset`.
    /// Returns the class_bytes blob.
    fn install_single_field_class(
        mem: &mut FakeMem,
        fields_addr: u64,
        name_addr: u64,
        type_addr: u64,
        name: &str,
        offset: i32,
    ) -> Vec<u8> {
        mem.add(
            fields_addr,
            make_field_entry(name_addr, type_addr, 0, offset),
        );
        let mut nb = name.as_bytes().to_vec();
        nb.push(0);
        mem.add(name_addr, nb);
        mem.add(type_addr, make_type_block(0));
        make_class_def(fields_addr, 1)
    }

    #[test]
    fn read_instance_i32_returns_value() -> Result<(), String> {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let class =
            install_single_field_class(&mut mem, 0x10_0000, 0x20_0000, 0x30_0000, "wcCommon", 0x50);
        let object_addr: u64 = 0x40_0000;
        let mut payload = vec![0u8; 0x80];
        payload[0x50..0x54].copy_from_slice(&42i32.to_le_bytes());
        mem.add(object_addr, payload);

        let got = read_instance_i32(&offsets, &class, object_addr, "wcCommon", &|a, l| {
            mem.read(a, l)
        })
        .ok_or("must resolve")?;
        assert_eq!(got, 42);
        Ok(())
    }

    #[test]
    fn read_instance_i32_returns_none_when_field_missing() {
        let offsets = MonoOffsets::mtga_default();
        let mem = FakeMem::default();
        let class = make_class_def(0, 0);
        assert_eq!(
            read_instance_i32(&offsets, &class, 0x40_0000, "missing", &|a, l| mem
                .read(a, l)),
            None
        );
    }

    #[test]
    fn read_instance_bool_decodes_nonzero_as_true() -> Result<(), String> {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let class = install_single_field_class(
            &mut mem,
            0x10_0000,
            0x20_0000,
            0x30_0000,
            "isPractice",
            0x10,
        );
        let object_addr: u64 = 0x40_0000;
        let mut payload = vec![0u8; 0x40];
        payload[0x10] = 1;
        mem.add(object_addr, payload);

        assert_eq!(
            read_instance_bool(&offsets, &class, object_addr, "isPractice", &|a, l| {
                mem.read(a, l)
            }),
            Some(true)
        );
        Ok(())
    }

    #[test]
    fn read_instance_f64_decodes_double() -> Result<(), String> {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let class = install_single_field_class(
            &mut mem,
            0x10_0000,
            0x20_0000,
            0x30_0000,
            "vaultProgress",
            0x70,
        );
        let object_addr: u64 = 0x40_0000;
        let mut payload = vec![0u8; 0x80];
        let value: f64 = 0.6789;
        payload[0x70..0x78].copy_from_slice(&value.to_bits().to_le_bytes());
        mem.add(object_addr, payload);

        let got = read_instance_f64(&offsets, &class, object_addr, "vaultProgress", &|a, l| {
            mem.read(a, l)
        })
        .ok_or("must resolve")?;
        assert!((got - 0.6789).abs() < 1e-12);
        Ok(())
    }

    #[test]
    fn read_instance_string_decodes_utf16() -> Result<(), String> {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let class = install_single_field_class(
            &mut mem,
            0x10_0000,
            0x20_0000,
            0x30_0000,
            "_screenName",
            0x10,
        );
        let object_addr: u64 = 0x40_0000;
        let str_ptr: u64 = 0x50_0000;
        let mut payload = vec![0u8; 0x40];
        payload[0x10..0x18].copy_from_slice(&str_ptr.to_le_bytes());
        mem.add(object_addr, payload);

        // MonoString header: vtable(8) + sync(8) + length:i32
        let s = "Hi 🦀";
        let utf16: Vec<u16> = s.encode_utf16().collect();
        let mut hdr = vec![0u8; 0x14];
        hdr[0x10..0x14].copy_from_slice(&(utf16.len() as i32).to_le_bytes());
        mem.add(str_ptr, hdr);
        let mut chars = Vec::with_capacity(utf16.len() * 2);
        for u in &utf16 {
            chars.extend_from_slice(&u.to_le_bytes());
        }
        mem.add(str_ptr + 0x14, chars);

        let got = read_instance_string(
            &offsets,
            &class,
            object_addr,
            "_screenName",
            256,
            &|a, l| mem.read(a, l),
        )
        .ok_or("must resolve")?;
        assert_eq!(got, s);
        Ok(())
    }

    #[test]
    fn read_instance_string_returns_none_on_null_ptr() {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let class = install_single_field_class(
            &mut mem,
            0x10_0000,
            0x20_0000,
            0x30_0000,
            "_screenName",
            0x10,
        );
        let object_addr: u64 = 0x40_0000;
        // Slot left as null (zero-initialised).
        mem.add(object_addr, vec![0u8; 0x40]);

        assert_eq!(
            read_instance_string(
                &offsets,
                &class,
                object_addr,
                "_screenName",
                256,
                &|a, l| { mem.read(a, l) }
            ),
            None
        );
    }

    #[test]
    fn read_instance_int_list_returns_empty_for_null_list() -> Result<(), String> {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let class = install_single_field_class(
            &mut mem,
            0x10_0000,
            0x20_0000,
            0x30_0000,
            "Commanders",
            0x18,
        );
        let object_addr: u64 = 0x40_0000;
        mem.add(object_addr, vec![0u8; 0x40]);

        let got =
            read_instance_int_list(&offsets, &class, object_addr, "Commanders", 32, &|a, l| {
                mem.read(a, l)
            })
            .ok_or("must resolve field")?;
        assert!(got.is_empty());
        Ok(())
    }

    #[test]
    fn read_instance_int_list_decodes_full_payload() -> Result<(), String> {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();

        // Container class: one field "Commanders" at +0x18.
        let class = install_single_field_class(
            &mut mem,
            0x10_0000,
            0x20_0000,
            0x30_0000,
            "Commanders",
            0x18,
        );

        // List<i32> runtime class: _items @ 0x10, _size @ 0x18.
        let list_fields_addr: u64 = 0x11_0000;
        let mut list_entries = Vec::with_capacity(2 * MONO_CLASS_FIELD_SIZE);
        let names = [(0x21_0000u64, "_items", 0x10), (0x21_0080, "_size", 0x18)];
        for (i, (name_ptr, name, offset)) in names.iter().enumerate() {
            let type_ptr = 0x31_0000 + (i as u64) * 0x20;
            list_entries.extend_from_slice(&make_field_entry(*name_ptr, type_ptr, 0, *offset));
            let mut nb = name.as_bytes().to_vec();
            nb.push(0);
            mem.add(*name_ptr, nb);
            mem.add(type_ptr, make_type_block(0));
        }
        mem.add(list_fields_addr, list_entries);
        let list_class_bytes = make_class_def(list_fields_addr, 2);

        // Container holds list_ptr at offset 0x18.
        let object_addr: u64 = 0x40_0000;
        let list_ptr: u64 = 0x50_0000;
        let mut container = vec![0u8; 0x40];
        container[0x18..0x20].copy_from_slice(&list_ptr.to_le_bytes());
        mem.add(object_addr, container);

        // List object: vtable(8) → vt → list_class_bytes; _items + _size payload.
        let vtable_addr: u64 = 0x60_0000;
        let class_def_addr: u64 = 0x70_0000;
        let items_ptr: u64 = 0x80_0000;
        let mut list_payload = vec![0u8; 0x30];
        list_payload[0..8].copy_from_slice(&vtable_addr.to_le_bytes());
        list_payload[0x10..0x18].copy_from_slice(&items_ptr.to_le_bytes());
        list_payload[0x18..0x1c].copy_from_slice(&3i32.to_le_bytes());
        mem.add(list_ptr, list_payload);

        let mut vt = vec![0u8; 0x10];
        vt[0..8].copy_from_slice(&class_def_addr.to_le_bytes());
        mem.add(vtable_addr, vt);
        mem.add(class_def_addr, list_class_bytes);

        // MonoArray<i32> elements at items_ptr + 0x20.
        let mut elements = Vec::new();
        for v in [11i32, 22, 33] {
            elements.extend_from_slice(&v.to_le_bytes());
        }
        mem.add(items_ptr + 0x20, elements);

        let got =
            read_instance_int_list(&offsets, &class, object_addr, "Commanders", 32, &|a, l| {
                mem.read(a, l)
            })
            .ok_or("must resolve")?;
        assert_eq!(got, vec![11, 22, 33]);
        Ok(())
    }
}
