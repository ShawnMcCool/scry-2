//! Walk a `Dictionary<int, int>._entries` array in the target
//! process.
//!
//! .NET's `Dictionary<TKey, TValue>` stores its payload in a
//! contiguous `Entry[]` array. For `Dictionary<int, int>` on .NET's
//! reference Mono runtime (which MTGA uses), each entry is exactly
//! 16 bytes:
//!
//! ```text
//! struct Entry {
//!     int hashCode;   // Mono hashes System.Int32 as key & 0x7FFFFFFF
//!     int next;       // index of next collision, or -1
//!     int key;
//!     int value;
//! }
//! ```
//!
//! The array is a `MonoArray<Entry>`, so it carries the standard
//! `MonoObject` + `bounds` + `max_length` header (32 bytes on MSVC
//! x86-64) before the element storage begins.
//!
//! `read_int_int_entries` walks every slot up to `max_length` and
//! returns only the **used** entries — i.e. those whose `hashCode`
//! matches `key & 0x7FFFFFFF`. Unused slots (left behind by
//! removals) have a different hashCode (usually `-1`) and are
//! filtered out.
//!
//! This is the same validity predicate the `mtga-duress` POC's
//! structural scanner uses — it is what distinguishes a live
//! `Dictionary<int, int>` from random int pairs in memory.

use super::mono::{MonoOffsets, DICT_INT_INT_ENTRY_SIZE};
use super::mono_array;

/// A used entry from a `Dictionary<int, int>`.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct DictEntry {
    pub key: i32,
    pub value: i32,
}

/// Re-export of the centralized cap. Defined in [`super::limits`].
pub use super::limits::MAX_DICT_INT_INT_ENTRIES as MAX_DICT_ENTRIES;

/// Walk a `Dictionary<int, int>._entries` `MonoArray` starting at
/// `array_remote_addr` in the target process.
///
/// `read_mem(addr, len)` is the caller-supplied byte reader (NIF
/// `read_bytes` in production, `HashMap`-backed stub in tests).
///
/// Returns `None` when:
/// - the `MonoArray` header cannot be read,
/// - the header's `max_length` exceeds [`MAX_DICT_ENTRIES`] (likely
///   garbage), or
/// - the bulk entry read fails.
///
/// Returns `Some(vec)` otherwise — possibly empty if no slots pass
/// the validity predicate.
pub fn read_int_int_entries<F>(
    offsets: &MonoOffsets,
    array_remote_addr: u64,
    read_mem: F,
) -> Option<Vec<DictEntry>>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let (capacity, blob) = mono_array::read_array_blob(
        offsets,
        array_remote_addr,
        DICT_INT_INT_ENTRY_SIZE,
        MAX_DICT_ENTRIES,
        &read_mem,
    )?;

    let mut used = Vec::new();
    for i in 0..capacity {
        let off = i * DICT_INT_INT_ENTRY_SIZE;
        let hash_code =
            i32::from_le_bytes([blob[off], blob[off + 1], blob[off + 2], blob[off + 3]]);
        // skip `next` at off+4..off+8 — unused for extraction
        let key =
            i32::from_le_bytes([blob[off + 8], blob[off + 9], blob[off + 10], blob[off + 11]]);
        let value = i32::from_le_bytes([
            blob[off + 12],
            blob[off + 13],
            blob[off + 14],
            blob[off + 15],
        ]);

        // Used-slot predicate: Mono's `System.Int32.GetHashCode()`
        // returns `value & 0x7FFFFFFF`. An unused slot has `hashCode`
        // set to something else (typically -1), which won't match.
        if hash_code == (key & 0x7FFF_FFFF) {
            used.push(DictEntry { key, value });
        }
    }
    Some(used)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a 32-byte MonoArray header with `max_length = capacity`.
    fn make_array_header(capacity: u64) -> Vec<u8> {
        let offsets = MonoOffsets::mtga_default();
        let mut v = vec![0u8; offsets.array_vector];
        v[offsets.array_max_length..offsets.array_max_length + 8]
            .copy_from_slice(&capacity.to_le_bytes());
        v
    }

    /// Write a single 16-byte Entry struct.
    fn make_entry(hash_code: i32, next: i32, key: i32, value: i32) -> [u8; 16] {
        let mut v = [0u8; 16];
        v[0..4].copy_from_slice(&hash_code.to_le_bytes());
        v[4..8].copy_from_slice(&next.to_le_bytes());
        v[8..12].copy_from_slice(&key.to_le_bytes());
        v[12..16].copy_from_slice(&value.to_le_bytes());
        v
    }

    /// Write a used entry (hashCode computed from key).
    fn used(key: i32, value: i32) -> [u8; 16] {
        make_entry(key & 0x7FFF_FFFF, -1, key, value)
    }

    /// Write an empty slot — hashCode = -1.
    fn empty_slot() -> [u8; 16] {
        make_entry(-1, -1, 0, 0)
    }

    /// Simulated remote memory with a single MonoArray present.
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

    fn fixture_with(entries: &[[u8; 16]]) -> Fixture {
        let offsets = MonoOffsets::mtga_default();
        let array_addr: u64 = 0xabcd_0000;
        let vector_addr = array_addr + offsets.array_vector as u64;
        let mut vector_bytes = Vec::with_capacity(entries.len() * DICT_INT_INT_ENTRY_SIZE);
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
        let result = read_int_int_entries(&offsets, array_addr, |a, l| {
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
        let fx = fixture_with(&[used(74116, 1), used(74117, 1), used(74118, 1)]);
        let got = read_int_int_entries(&offsets, fx.array_addr, |a, l| fx.read(a, l))
            .ok_or("should return Some")?;
        assert_eq!(
            got,
            vec![
                DictEntry {
                    key: 74116,
                    value: 1
                },
                DictEntry {
                    key: 74117,
                    value: 1
                },
                DictEntry {
                    key: 74118,
                    value: 1
                },
            ]
        );
        Ok(())
    }

    #[test]
    fn filters_out_empty_slots() -> Result<(), String> {
        let offsets = MonoOffsets::mtga_default();
        let fx = fixture_with(&[
            used(32388, 4),
            empty_slot(),
            used(74120, 2),
            empty_slot(),
            empty_slot(),
            used(106_219, 1),
        ]);
        let got = read_int_int_entries(&offsets, fx.array_addr, |a, l| fx.read(a, l))
            .ok_or("should return Some")?;
        assert_eq!(
            got,
            vec![
                DictEntry {
                    key: 32388,
                    value: 4
                },
                DictEntry {
                    key: 74120,
                    value: 2
                },
                DictEntry {
                    key: 106_219,
                    value: 1
                },
            ]
        );
        Ok(())
    }

    #[test]
    fn filters_out_entries_whose_hash_disagrees_with_key() -> Result<(), String> {
        // A stale/removed entry can retain the old key/value but have a
        // scrambled hashCode. The predicate must reject these.
        let offsets = MonoOffsets::mtga_default();
        let fx = fixture_with(&[
            used(100, 5),
            make_entry(42, -1, 100, 7), // hashCode=42, key=100 — fails
            used(200, 8),
        ]);
        let got = read_int_int_entries(&offsets, fx.array_addr, |a, l| fx.read(a, l))
            .ok_or("should return Some")?;
        assert_eq!(
            got,
            vec![
                DictEntry { key: 100, value: 5 },
                DictEntry { key: 200, value: 8 },
            ]
        );
        Ok(())
    }

    #[test]
    fn returns_none_when_header_read_fails() {
        let offsets = MonoOffsets::mtga_default();
        let result = read_int_int_entries(&offsets, 0x2000, |_, _| None);
        assert_eq!(result, None);
    }

    #[test]
    fn returns_none_when_max_length_exceeds_cap() {
        let offsets = MonoOffsets::mtga_default();
        let array_addr: u64 = 0x3000;
        let header = make_array_header(MAX_DICT_ENTRIES + 1);
        let result = read_int_int_entries(&offsets, array_addr, |a, l| {
            if a == array_addr {
                Some(header[..l.min(header.len())].to_vec())
            } else {
                None
            }
        });
        assert_eq!(result, None);
    }

    #[test]
    fn returns_none_when_vector_bulk_read_fails() {
        // Header read succeeds, but the vector read misses.
        let offsets = MonoOffsets::mtga_default();
        let array_addr: u64 = 0x4000;
        let header = make_array_header(4);
        let result = read_int_int_entries(&offsets, array_addr, |a, l| {
            if a == array_addr {
                Some(header[..l.min(header.len())].to_vec())
            } else {
                None
            }
        });
        assert_eq!(result, None);
    }

    #[test]
    fn treats_negative_keys_correctly() -> Result<(), String> {
        // Mono hashes System.Int32 as (value & 0x7FFFFFFF) — for a
        // negative key, hashCode is the *unsigned* positive form. The
        // walker must still match.
        let offsets = MonoOffsets::mtga_default();
        let fx = fixture_with(&[used(-42, 99)]);
        let got = read_int_int_entries(&offsets, fx.array_addr, |a, l| fx.read(a, l))
            .ok_or("should return Some")?;
        assert_eq!(
            got,
            vec![DictEntry {
                key: -42,
                value: 99
            }]
        );
        Ok(())
    }

    #[test]
    fn handles_capacity_of_one() -> Result<(), String> {
        let offsets = MonoOffsets::mtga_default();
        let fx = fixture_with(&[used(7, 13)]);
        let got = read_int_int_entries(&offsets, fx.array_addr, |a, l| fx.read(a, l))
            .ok_or("should return Some")?;
        assert_eq!(got, vec![DictEntry { key: 7, value: 13 }]);
        Ok(())
    }

    #[test]
    fn replays_spike_7_sample_distribution() -> Result<(), String> {
        // spike 7's POC reported count distribution `{1: 1994, 2: 707,
        // 3: 376, 4: 1014}` for 4091 entries. Simulate a smaller
        // mix-of-copies scenario and verify the walker preserves both
        // the keys and the value counts.
        let offsets = MonoOffsets::mtga_default();
        let entries = vec![
            used(32388, 4), // 4-of
            empty_slot(),
            used(74116, 1),   // singleton
            used(74117, 1),   // singleton
            used(100_100, 2), // 2-of
            empty_slot(),
            used(106_219, 3), // 3-of
        ];
        let fx = fixture_with(&entries);
        let got = read_int_int_entries(&offsets, fx.array_addr, |a, l| fx.read(a, l))
            .ok_or("should return Some")?;
        let sum: i32 = got.iter().map(|e| e.value).sum();
        assert_eq!(sum, 4 + 1 + 1 + 2 + 3);
        assert_eq!(got.len(), 5);
        Ok(())
    }
}
