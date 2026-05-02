//! Walk a `Dictionary<int, ptr>._entries` array — generic over reference-
//! typed values.
//!
//! `dict.rs` covers `Dictionary<int, int>` (16-byte entries, both key and
//! value as inline i32). Chain 2 of the match-state walker needs
//! `Dictionary<int, T>` where `T` is a reference type (a managed pointer,
//! 8 bytes on x86-64). The two cases differ only in entry size and value
//! layout:
//!
//! ```text
//! struct Entry<int, ptr> {
//!     int hashCode;   // offset 0
//!     int next;       // offset 4
//!     int key;        // offset 8
//!     // 4 bytes padding to align `value` to 8 bytes (Mono MSVC ABI).
//!     ptr value;      // offset 16
//! };                  // sizeof = 24
//! ```
//!
//! Used-slot predicate is identical to the int/int case — Mono hashes
//! `System.Int32` as `key & 0x7FFFFFFF`. Slots that fail the predicate
//! (typically `hashCode = -1` for removed entries) are filtered out.
//!
//! Returns `Option<Vec<DictPtrEntry>>`. The `value` pointer can be
//! null for entries whose value reference was never assigned — those
//! pass through as `value: 0` and the caller decides whether to skip.

use super::mono::{self, MonoOffsets};
use super::mono_array;

/// Layout constants for `Dictionary<int, ptr>.Entry` on Mono x86-64.
pub const DICT_INT_PTR_ENTRY_SIZE: usize = 24;
const DICT_INT_PTR_KEY_OFFSET: usize = 8;
const DICT_INT_PTR_VALUE_OFFSET: usize = 16;

/// A used entry from a `Dictionary<int, ptr>`.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct DictPtrEntry {
    pub key: i32,
    pub value: u64,
}

/// Re-export of the centralized cap. Defined in [`super::limits`].
pub use super::limits::MAX_DICT_INT_PTR_ENTRIES as MAX_DICT_PTR_ENTRIES;

/// Walk a `Dictionary<int, ptr>._entries` `MonoArray` starting at
/// `array_remote_addr` in the target process.
///
/// Returns `None` when:
/// - the `MonoArray` header cannot be read,
/// - the header's `max_length` exceeds [`MAX_DICT_PTR_ENTRIES`], or
/// - the bulk entry read fails.
///
/// Returns `Some(vec)` otherwise — possibly empty if no slots pass
/// the validity predicate.
pub fn read_int_ptr_entries<F>(
    offsets: &MonoOffsets,
    array_remote_addr: u64,
    read_mem: F,
) -> Option<Vec<DictPtrEntry>>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let (capacity, blob) = mono_array::read_array_blob(
        offsets,
        array_remote_addr,
        DICT_INT_PTR_ENTRY_SIZE,
        MAX_DICT_PTR_ENTRIES,
        &read_mem,
    )?;

    let mut used = Vec::new();
    for i in 0..capacity {
        let off = i * DICT_INT_PTR_ENTRY_SIZE;
        let hash_code =
            i32::from_le_bytes([blob[off], blob[off + 1], blob[off + 2], blob[off + 3]]);
        let key_off = off + DICT_INT_PTR_KEY_OFFSET;
        let key = i32::from_le_bytes([
            blob[key_off],
            blob[key_off + 1],
            blob[key_off + 2],
            blob[key_off + 3],
        ]);
        let value_off = off + DICT_INT_PTR_VALUE_OFFSET;
        let value = u64::from_le_bytes([
            blob[value_off],
            blob[value_off + 1],
            blob[value_off + 2],
            blob[value_off + 3],
            blob[value_off + 4],
            blob[value_off + 5],
            blob[value_off + 6],
            blob[value_off + 7],
        ]);

        if hash_code == (key & 0x7FFF_FFFF) {
            used.push(DictPtrEntry { key, value });
        }
    }
    Some(used)
}

/// Resolve a Dictionary's `_entries` `MonoArray` pointer from a
/// dictionary object's runtime-class blob.
///
/// `Dictionary<TKey, TValue>` always carries an `_entries` field of
/// type `Entry[]` (a managed array). The walker resolves this field
/// dynamically by name — that handles both the literal `_entries`
/// name (Mono runtime) and any backing-field variant.
pub fn entries_array_addr<F>(
    offsets: &MonoOffsets,
    dict_class_bytes: &[u8],
    dict_object_addr: u64,
    read_mem: &F,
) -> Option<u64>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let resolved =
        super::field::find_field_by_name(offsets, dict_class_bytes, "_entries", read_mem)?;
    if resolved.is_static || resolved.offset < 0 {
        return None;
    }
    let slot = dict_object_addr.checked_add(resolved.offset as u64)?;
    let bytes = read_mem(slot, 8)?;
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

    fn make_array_header(capacity: u64) -> Vec<u8> {
        let offsets = MonoOffsets::mtga_default();
        let mut v = vec![0u8; offsets.array_vector];
        v[offsets.array_max_length..offsets.array_max_length + 8]
            .copy_from_slice(&capacity.to_le_bytes());
        v
    }

    fn make_entry(hash_code: i32, next: i32, key: i32, value: u64) -> [u8; 24] {
        let mut v = [0u8; 24];
        v[0..4].copy_from_slice(&hash_code.to_le_bytes());
        v[4..8].copy_from_slice(&next.to_le_bytes());
        v[8..12].copy_from_slice(&key.to_le_bytes());
        // 12..16 padding
        v[16..24].copy_from_slice(&value.to_le_bytes());
        v
    }

    fn used(key: i32, value: u64) -> [u8; 24] {
        make_entry(key & 0x7FFF_FFFF, -1, key, value)
    }

    fn empty_slot() -> [u8; 24] {
        make_entry(-1, -1, 0, 0)
    }

    struct Fixture {
        array_addr: u64,
        header: Vec<u8>,
        vector_addr: u64,
        vector_bytes: Vec<u8>,
    }

    impl Fixture {
        fn read(&self, addr: u64, len: usize) -> Option<Vec<u8>> {
            if addr == self.array_addr {
                let end = len.min(self.header.len());
                return Some(self.header[..end].to_vec());
            }
            if addr >= self.vector_addr {
                let off = (addr - self.vector_addr) as usize;
                if off < self.vector_bytes.len() {
                    let end = off.saturating_add(len).min(self.vector_bytes.len());
                    return Some(self.vector_bytes[off..end].to_vec());
                }
            }
            None
        }
    }

    fn fixture_with(entries: &[[u8; 24]]) -> Fixture {
        let offsets = MonoOffsets::mtga_default();
        let array_addr: u64 = 0xabcd_0000;
        let vector_addr = array_addr + offsets.array_vector as u64;
        let mut vector_bytes = Vec::with_capacity(entries.len() * DICT_INT_PTR_ENTRY_SIZE);
        for e in entries {
            vector_bytes.extend_from_slice(e);
        }
        Fixture {
            array_addr,
            header: make_array_header(entries.len() as u64),
            vector_addr,
            vector_bytes,
        }
    }

    #[test]
    fn returns_empty_for_zero_capacity() {
        let offsets = MonoOffsets::mtga_default();
        let array_addr: u64 = 0x1000;
        let header = make_array_header(0);
        let result = read_int_ptr_entries(&offsets, array_addr, |a, l| {
            if a == array_addr {
                Some(header[..l.min(header.len())].to_vec())
            } else {
                None
            }
        });
        assert_eq!(result, Some(vec![]));
    }

    #[test]
    fn returns_all_used_entries_in_order() -> Result<(), String> {
        let offsets = MonoOffsets::mtga_default();
        let fx = fixture_with(&[
            used(0, 0xdead_0000_0000_0001),
            used(1, 0xdead_0000_0000_0002),
            used(2, 0xdead_0000_0000_0003),
        ]);
        let got = read_int_ptr_entries(&offsets, fx.array_addr, |a, l| fx.read(a, l))
            .ok_or("should return Some")?;
        assert_eq!(
            got,
            vec![
                DictPtrEntry {
                    key: 0,
                    value: 0xdead_0000_0000_0001
                },
                DictPtrEntry {
                    key: 1,
                    value: 0xdead_0000_0000_0002
                },
                DictPtrEntry {
                    key: 2,
                    value: 0xdead_0000_0000_0003
                },
            ]
        );
        Ok(())
    }

    #[test]
    fn filters_out_empty_slots() -> Result<(), String> {
        let offsets = MonoOffsets::mtga_default();
        let fx = fixture_with(&[
            used(0, 0xaaaa),
            empty_slot(),
            used(1, 0xbbbb),
            empty_slot(),
            used(2, 0xcccc),
        ]);
        let got = read_int_ptr_entries(&offsets, fx.array_addr, |a, l| fx.read(a, l))
            .ok_or("should return Some")?;
        assert_eq!(got.len(), 3);
        assert_eq!(got[0].value, 0xaaaa);
        assert_eq!(got[1].value, 0xbbbb);
        assert_eq!(got[2].value, 0xcccc);
        Ok(())
    }

    #[test]
    fn preserves_null_value_pointers_for_used_entries() -> Result<(), String> {
        // A used Dictionary entry can legally have value = null (the
        // value reference was set to null after insertion). The walker
        // returns it as `value: 0` and lets the caller filter.
        let offsets = MonoOffsets::mtga_default();
        let fx = fixture_with(&[used(7, 0)]);
        let got = read_int_ptr_entries(&offsets, fx.array_addr, |a, l| fx.read(a, l))
            .ok_or("should return Some")?;
        assert_eq!(got, vec![DictPtrEntry { key: 7, value: 0 }]);
        Ok(())
    }

    #[test]
    fn returns_none_when_max_length_exceeds_cap() {
        let offsets = MonoOffsets::mtga_default();
        let array_addr: u64 = 0x3000;
        let header = make_array_header(MAX_DICT_PTR_ENTRIES + 1);
        let result = read_int_ptr_entries(&offsets, array_addr, |a, l| {
            if a == array_addr {
                Some(header[..l.min(header.len())].to_vec())
            } else {
                None
            }
        });
        assert_eq!(result, None);
    }

    #[test]
    fn returns_none_when_header_read_fails() {
        let offsets = MonoOffsets::mtga_default();
        let result = read_int_ptr_entries(&offsets, 0x2000, |_, _| None);
        assert_eq!(result, None);
    }
}
