//! Shared test scaffolding for walker unit tests.
//!
//! Every walker module historically grew its own copy of `FakeMem` plus
//! `make_class_def` / `make_field_entry` / `make_type_block` / etc. This
//! module is the canonical home — addresses finding 2.1 of the
//! engineering audit.
//!
//! `FakeMem` validates on insertion that no block overlaps another
//! (finding 5.4): a fixture-setup error panics immediately rather than
//! silently shadowing later writes during reads.
//!
//! Compiled only under `#[cfg(test)]`.

#![cfg(test)]

use super::mono::{MonoOffsets, CLASS_DEF_BLOB_LEN, MONO_CLASS_FIELD_SIZE};

/// Synthetic remote-process memory keyed by absolute address.
///
/// Reads return `Some(slice)` when the requested `(addr, len)` falls
/// inside any installed block, walking the most-recently-added block
/// first (so a deliberate later insertion can override an earlier one
/// — used by some negative-path tests). Insertion `panic!`s on
/// overlap to prevent silent fixture errors.
#[derive(Default)]
pub struct FakeMem {
    blocks: Vec<(u64, Vec<u8>)>,
}

impl FakeMem {
    /// Install `bytes` starting at `addr`. Panics if the new block
    /// overlaps any installed block — overlaps would silently shadow
    /// reads and mask fixture bugs. (Test-only; the panic is the
    /// fail-fast contract of the fixture, not a production code path.)
    #[allow(clippy::panic)]
    pub fn add(&mut self, addr: u64, bytes: Vec<u8>) {
        let new_start = addr;
        let new_end = addr.saturating_add(bytes.len() as u64);
        for (existing_start, existing) in &self.blocks {
            let existing_end = existing_start.saturating_add(existing.len() as u64);
            if new_start < existing_end && *existing_start < new_end {
                panic!(
                    "FakeMem block overlap: new [{:#x}, {:#x}) overlaps existing [{:#x}, {:#x})",
                    new_start, new_end, existing_start, existing_end
                );
            }
        }
        self.blocks.push((addr, bytes));
    }

    /// Replace any installed block(s) at `addr` outright. Used by
    /// negative-path tests that want to overwrite a populated slot
    /// (e.g. flip a pointer to NULL) without tripping overlap
    /// detection.
    pub fn replace(&mut self, addr: u64, bytes: Vec<u8>) {
        let new_end = addr.saturating_add(bytes.len() as u64);
        self.blocks.retain(|(existing_start, existing)| {
            let existing_end = existing_start.saturating_add(existing.len() as u64);
            !(addr < existing_end && *existing_start < new_end)
        });
        self.blocks.push((addr, bytes));
    }

    /// Read `len` bytes at `addr`. Returns `Some(bytes)` from the most-
    /// recently-installed block containing `addr`, or `None` if no
    /// block covers `addr`.
    pub fn read(&self, addr: u64, len: usize) -> Option<Vec<u8>> {
        for (base, data) in self.blocks.iter().rev() {
            if addr >= *base {
                let off = (addr - *base) as usize;
                if off < data.len() {
                    let end = off.saturating_add(len).min(data.len());
                    return Some(data[off..end].to_vec());
                }
            }
        }
        None
    }
}

/// Build a 32-byte `MonoClassField` entry at the canonical offsets.
/// `parent_ptr` defaults to 0 if the test doesn't care.
pub fn make_field_entry(name_ptr: u64, type_ptr: u64, parent_ptr: u64, offset: i32) -> Vec<u8> {
    let o = MonoOffsets::mtga_default();
    let mut v = vec![0u8; MONO_CLASS_FIELD_SIZE];
    v[o.field_type..o.field_type + 8].copy_from_slice(&type_ptr.to_le_bytes());
    v[o.field_name..o.field_name + 8].copy_from_slice(&name_ptr.to_le_bytes());
    v[o.field_parent..o.field_parent + 8].copy_from_slice(&parent_ptr.to_le_bytes());
    v[o.field_offset..o.field_offset + 4].copy_from_slice(&(offset as u32).to_le_bytes());
    v
}

/// Build a 16-byte `MonoType` block carrying `attrs` at offset 0x08.
/// Pass `MONO_FIELD_ATTR_STATIC` for static fields, `0` otherwise.
pub fn make_type_block(attrs: u16) -> Vec<u8> {
    let mut v = vec![0u8; 16];
    v[8..12].copy_from_slice(&(attrs as u32).to_le_bytes());
    v
}

/// Build a `MonoClassDef`-sized blob carrying `fields_ptr` and
/// `field_count` at the canonical offsets, padded to
/// [`CLASS_DEF_BLOB_LEN`].
pub fn make_class_def(fields_ptr: u64, field_count: u32) -> Vec<u8> {
    let o = MonoOffsets::mtga_default();
    let mut buf = vec![0u8; CLASS_DEF_BLOB_LEN];
    buf[o.class_fields..o.class_fields + 8].copy_from_slice(&fields_ptr.to_le_bytes());
    buf[o.class_def_field_count..o.class_def_field_count + 4]
        .copy_from_slice(&field_count.to_le_bytes());
    buf
}

#[cfg(test)]
mod self_tests {
    use super::*;

    #[test]
    fn fake_mem_round_trips_a_block() {
        let mut mem = FakeMem::default();
        mem.add(0x1000, vec![1, 2, 3, 4]);
        assert_eq!(mem.read(0x1000, 4), Some(vec![1, 2, 3, 4]));
        assert_eq!(mem.read(0x1002, 2), Some(vec![3, 4]));
    }

    #[test]
    fn fake_mem_returns_none_for_unmapped_address() {
        let mem = FakeMem::default();
        assert_eq!(mem.read(0x1000, 4), None);
    }

    #[test]
    #[should_panic(expected = "overlap")]
    fn fake_mem_panics_on_overlapping_add() {
        let mut mem = FakeMem::default();
        mem.add(0x1000, vec![0u8; 0x100]);
        mem.add(0x1080, vec![0u8; 0x10]); // overlaps [0x1000, 0x1100)
    }

    #[test]
    fn fake_mem_replace_overwrites_existing_block() {
        let mut mem = FakeMem::default();
        mem.add(0x1000, vec![1u8; 4]);
        mem.replace(0x1000, vec![9u8; 4]);
        assert_eq!(mem.read(0x1000, 4), Some(vec![9u8; 4]));
    }
}
