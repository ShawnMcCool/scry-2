//! Read Mono `List<T>` instances.
//!
//! `System.Collections.Generic.List<T>` layout (Mono, x86-64):
//!
//! ```text
//! +0x00  vtable                    : MonoObject header
//! +0x08  sync
//! +0x10  _items                    : T[] *      (managed array)
//! +0x18  _size                     : i32        (used count)
//! +0x1c  _version                  : i32
//! +0x20  _syncRoot                 : object *
//! ```
//!
//! `_items` points to a `MonoArray<T>` whose element storage starts
//! at `array_base + 0x20` (per the `MonoArray` offsets pinned in
//! `mono.rs`).
//!
//! Field names are resolved dynamically via [`super::field::find_field_by_name`]
//! against the list's runtime class — different closed-generic
//! instantiations share the same field layout, but resolving by name
//! is cheap and keeps the walker resilient to layout shifts.

use super::instance_field;
use super::mono::MonoOffsets;
use super::mono_array;
use super::object;

/// Read the `_size` (used count) of a `List<T>` instance.
pub fn read_size<F>(
    offsets: &MonoOffsets,
    list_class_bytes: &[u8],
    list_addr: u64,
    read_mem: &F,
) -> Option<i32>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    instance_field::read_instance_i32(offsets, list_class_bytes, list_addr, "_size", read_mem)
}

/// Read the `_items` pointer (the `T[]` array) of a `List<T>` instance.
///
/// Returns `None` on null or unresolved.
pub fn read_items_ptr<F>(
    offsets: &MonoOffsets,
    list_class_bytes: &[u8],
    list_addr: u64,
    read_mem: &F,
) -> Option<u64>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    object::read_instance_pointer(offsets, list_class_bytes, list_addr, "_items", read_mem)
}

/// Read a `List<int>` (or `List<i32>`) into a `Vec<i32>`.
///
/// `list_class_bytes` is the `MonoClassDef`-blob for the list's
/// runtime class — caller resolves it from `(list_addr).vtable.klass`.
/// Returns an empty vec for empty / null / unreadable lists. Capped
/// at `MAX_ELEMENTS` (1024) to avoid runaway allocation if state
/// tearing produces an absurd `_size`.
pub fn read_int_list<F>(
    offsets: &MonoOffsets,
    list_class_bytes: &[u8],
    list_addr: u64,
    read_mem: &F,
) -> Vec<i32>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let size = read_size(offsets, list_class_bytes, list_addr, read_mem).unwrap_or(0);
    if size <= 0 {
        return Vec::new();
    }
    let count = (size as usize).min(MAX_ELEMENTS);
    let Some(items_ptr) = read_items_ptr(offsets, list_class_bytes, list_addr, read_mem) else {
        return Vec::new();
    };
    let Some(bytes) =
        mono_array::read_array_elements(items_ptr, MONO_ARRAY_VECTOR_OFFSET, count, 4, read_mem)
    else {
        return Vec::new();
    };
    bytes
        .chunks_exact(4)
        .map(|c| i32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect()
}

/// Read a `List<TRef>` (where T is a reference type) into a `Vec<u64>`
/// of object pointers. Caller dereferences each one to get the actual
/// objects.
///
/// Useful for `List<PlayerInfo>`, `List<CardLayoutData>`, etc.
pub fn read_pointer_list<F>(
    offsets: &MonoOffsets,
    list_class_bytes: &[u8],
    list_addr: u64,
    read_mem: &F,
) -> Vec<u64>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let size = read_size(offsets, list_class_bytes, list_addr, read_mem).unwrap_or(0);
    if size <= 0 {
        return Vec::new();
    }
    let count = (size as usize).min(MAX_ELEMENTS);
    let Some(items_ptr) = read_items_ptr(offsets, list_class_bytes, list_addr, read_mem) else {
        return Vec::new();
    };
    let Some(bytes) =
        mono_array::read_array_elements(items_ptr, MONO_ARRAY_VECTOR_OFFSET, count, 8, read_mem)
    else {
        return Vec::new();
    };
    bytes
        .chunks_exact(8)
        .filter_map(|c| {
            let p = u64::from_le_bytes([c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7]]);
            if p == 0 {
                None
            } else {
                Some(p)
            }
        })
        .collect()
}

/// MonoArray's element storage starts at `array_base + 0x20` — the
/// flex `vector[]` field after the 32-byte header. Pinned in
/// `mono.rs` for the inventory walker; mirrored here for clarity.
const MONO_ARRAY_VECTOR_OFFSET: u64 = 0x20;

/// Re-export of the centralized cap. Defined in [`super::limits`].
pub use super::limits::MAX_LIST_ELEMENTS as MAX_ELEMENTS;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::walker::mono::MONO_CLASS_FIELD_SIZE;
    use crate::walker::test_support::{make_class_def, make_type_block, FakeMem};

    fn make_field_entry(name_ptr: u64, type_ptr: u64, offset: i32) -> Vec<u8> {
        crate::walker::test_support::make_field_entry(name_ptr, type_ptr, 0, offset)
    }

    /// Build a List<T> class def with `_items @ 0x10` and `_size @ 0x18`.
    fn build_list_class_bytes(mem: &mut FakeMem, base_addr: u64) -> Vec<u8> {
        let names_base = base_addr + 0x1_0000;
        let types_base = base_addr + 0x2_0000;
        let fields_array = base_addr + 0x3_0000;

        let mut entries = Vec::with_capacity(2 * MONO_CLASS_FIELD_SIZE);
        for (i, (name, offset)) in [("_items", 0x10), ("_size", 0x18)].iter().enumerate() {
            let np = names_base + (i as u64) * 0x40;
            let tp = types_base + (i as u64) * 0x20;
            entries.extend_from_slice(&make_field_entry(np, tp, *offset));
            let mut nb = name.as_bytes().to_vec();
            nb.push(0);
            mem.add(np, nb);
            mem.add(tp, make_type_block(0));
        }
        mem.add(fields_array, entries);
        make_class_def(fields_array, 2)
    }

    /// Install a List<T> object at `list_addr` with the given element
    /// payload at `items_ptr + 0x20`.
    fn install_list(
        mem: &mut FakeMem,
        list_addr: u64,
        size: i32,
        items_ptr: u64,
        elements: Vec<u8>,
    ) {
        let mut payload = vec![0u8; 0x30];
        payload[0x10..0x18].copy_from_slice(&items_ptr.to_le_bytes());
        payload[0x18..0x1c].copy_from_slice(&size.to_le_bytes());
        mem.add(list_addr, payload);
        mem.add(items_ptr + MONO_ARRAY_VECTOR_OFFSET, elements);
    }

    #[test]
    fn read_int_list_returns_full_payload() {
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();
        let class_bytes = build_list_class_bytes(&mut mem, 0x1000_0000);

        let list_addr: u64 = 0x2000_0000;
        let items_ptr: u64 = 0x3000_0000;
        let mut elements = Vec::new();
        for v in [42i32, 17, 5, 2, 7777] {
            elements.extend_from_slice(&v.to_le_bytes());
        }
        install_list(&mut mem, list_addr, 5, items_ptr, elements);

        let result = read_int_list(&offsets, &class_bytes, list_addr, &|a, l| mem.read(a, l));
        assert_eq!(result, vec![42, 17, 5, 2, 7777]);
    }

    #[test]
    fn read_int_list_returns_empty_for_zero_size() {
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();
        let class_bytes = build_list_class_bytes(&mut mem, 0x1000_0000);

        let list_addr: u64 = 0x2000_0000;
        let items_ptr: u64 = 0x3000_0000;
        install_list(&mut mem, list_addr, 0, items_ptr, vec![]);

        let result = read_int_list(&offsets, &class_bytes, list_addr, &|a, l| mem.read(a, l));
        assert!(result.is_empty());
    }

    #[test]
    fn read_int_list_caps_at_max_elements() {
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();
        let class_bytes = build_list_class_bytes(&mut mem, 0x1000_0000);

        let list_addr: u64 = 0x2000_0000;
        let items_ptr: u64 = 0x3000_0000;
        // Insane _size value that would otherwise cause a 4-GB read.
        let bogus_size = 1_000_000_000;
        let elements = vec![0u8; (MAX_ELEMENTS + 50) * 4];
        install_list(&mut mem, list_addr, bogus_size, items_ptr, elements);

        let result = read_int_list(&offsets, &class_bytes, list_addr, &|a, l| mem.read(a, l));
        assert_eq!(result.len(), MAX_ELEMENTS, "must cap at MAX_ELEMENTS");
    }

    #[test]
    fn read_pointer_list_strips_nulls() {
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();
        let class_bytes = build_list_class_bytes(&mut mem, 0x1000_0000);

        let list_addr: u64 = 0x2000_0000;
        let items_ptr: u64 = 0x3000_0000;
        let ptrs: [u64; 4] = [0x100, 0x0, 0x200, 0x300];
        let mut elements = Vec::new();
        for p in &ptrs {
            elements.extend_from_slice(&p.to_le_bytes());
        }
        install_list(&mut mem, list_addr, 4, items_ptr, elements);

        let result = read_pointer_list(&offsets, &class_bytes, list_addr, &|a, l| mem.read(a, l));
        assert_eq!(result, vec![0x100, 0x200, 0x300]);
    }

    #[test]
    fn read_size_returns_none_for_unresolved_field() {
        // Class with no _size field at all.
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();
        let class_bytes = make_class_def(0, 0);

        let list_addr: u64 = 0x2000_0000;
        mem.add(list_addr, vec![0u8; 0x30]);

        let result = read_size(&offsets, &class_bytes, list_addr, &|a, l| mem.read(a, l));
        assert!(result.is_none());
    }
}
