//! Read MTGA's `ClientPlayerInventory` plain fields.
//!
//! The pointer chain from spike 5 ends at `ClientPlayerInventory` as
//! a plain-struct sibling of the `Cards` dictionary on the
//! `InventoryServiceWrapper`. Its fields carry wildcard counts,
//! soft/hard currency, and vault progress:
//!
//! | Name | Purpose |
//! |---|---|
//! | `wcCommon` | common wildcards held |
//! | `wcUncommon` | uncommon wildcards held |
//! | `wcRare` | rare wildcards held |
//! | `wcMythic` | mythic wildcards held |
//! | `gold` | soft currency (gold pieces) |
//! | `gems` | hard currency (gems) |
//! | `vaultProgress` | progress toward the next vault opening |
//!
//! Per spike 5 every one of these is a literal field name (no
//! `<...>k__BackingField` decoration), so `field::find_by_name`
//! resolves each with its exact-match pass.
//!
//! Each value is stored as a 32-bit little-endian word. The exact
//! C# type for `vaultProgress` is ambiguous from static analysis —
//! it is exposed as `i32` here; a caller that later identifies it as
//! `float` can reinterpret via `f32::from_bits(value as u32)`
//! without the walker changing shape.

use super::field::{self, ResolvedField};
use super::mono::{self, MonoOffsets};

/// Snapshot of one `ClientPlayerInventory` read.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct InventoryValues {
    pub wc_common: i32,
    pub wc_uncommon: i32,
    pub wc_rare: i32,
    pub wc_mythic: i32,
    pub gold: i32,
    pub gems: i32,
    pub vault_progress: i32,
}

/// The seven field names the walker resolves on `ClientPlayerInventory`,
/// in the order they appear in `InventoryValues`.
pub const FIELD_NAMES: [&str; 7] = [
    "wcCommon",
    "wcUncommon",
    "wcRare",
    "wcMythic",
    "gold",
    "gems",
    "vaultProgress",
];

/// Read `ClientPlayerInventory`'s seven plain fields from a live
/// object at `object_remote_addr`.
///
/// `class_bytes` must contain the bytes of the inventory's
/// `MonoClassDef` (large enough to cover `MonoClass.fields` at
/// `0x98` and `MonoClassDef.field_count` at `0x100`, i.e. at least
/// `class_base + 0x104` bytes).
///
/// Returns `None` if any single field fails to resolve or any read
/// misses — all seven are required for a usable snapshot.
pub fn read_inventory<F>(
    offsets: &MonoOffsets,
    class_bytes: &[u8],
    class_base: usize,
    object_remote_addr: u64,
    read_mem: F,
) -> Option<InventoryValues>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let mut values = [0i32; 7];
    for (i, name) in FIELD_NAMES.iter().enumerate() {
        let resolved = resolve_and_read_i32(
            offsets,
            class_bytes,
            class_base,
            object_remote_addr,
            name,
            &read_mem,
        )?;
        values[i] = resolved;
    }
    Some(InventoryValues {
        wc_common: values[0],
        wc_uncommon: values[1],
        wc_rare: values[2],
        wc_mythic: values[3],
        gold: values[4],
        gems: values[5],
        vault_progress: values[6],
    })
}

fn resolve_and_read_i32<F>(
    offsets: &MonoOffsets,
    class_bytes: &[u8],
    class_base: usize,
    object_remote_addr: u64,
    field_name: &str,
    read_mem: &F,
) -> Option<i32>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let resolved: ResolvedField =
        field::find_by_name(offsets, class_bytes, class_base, field_name, read_mem)?;
    if resolved.is_static || resolved.offset < 0 {
        return None;
    }
    let value_addr = object_remote_addr.checked_add(resolved.offset as u64)?;
    let bytes = read_mem(value_addr, 4)?;
    mono::read_u32(&bytes, 0, 0).map(|v| v as i32)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::walker::mono::MONO_CLASS_FIELD_SIZE;

    /// FakeMem that honours `(addr + offset, len) → slice_of_block`
    /// lookups, picking the block whose base most closely precedes
    /// `addr`.
    #[derive(Default)]
    struct FakeMem {
        blocks: Vec<(u64, Vec<u8>)>,
    }

    impl FakeMem {
        fn add(&mut self, addr: u64, bytes: Vec<u8>) {
            self.blocks.push((addr, bytes));
        }

        fn read(&self, addr: u64, len: usize) -> Option<Vec<u8>> {
            for (base, data) in &self.blocks {
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

    /// Build the MonoClassDef buffer for an inventory class. `fields_ptr`
    /// and `field_count` reflect the array the test will populate.
    fn make_class_def(fields_ptr: u64, field_count: u32) -> Vec<u8> {
        let offsets = MonoOffsets::mtga_default();
        let mut buf = vec![0u8; 0x110];
        buf[offsets.class_fields..offsets.class_fields + 8]
            .copy_from_slice(&fields_ptr.to_le_bytes());
        buf[offsets.class_def_field_count..offsets.class_def_field_count + 4]
            .copy_from_slice(&field_count.to_le_bytes());
        buf
    }

    /// Build a 32-byte MonoClassField entry.
    fn make_field_entry(name_ptr: u64, type_ptr: u64, offset: i32) -> Vec<u8> {
        let o = MonoOffsets::mtga_default();
        let mut v = vec![0u8; MONO_CLASS_FIELD_SIZE];
        v[o.field_type..o.field_type + 8].copy_from_slice(&type_ptr.to_le_bytes());
        v[o.field_name..o.field_name + 8].copy_from_slice(&name_ptr.to_le_bytes());
        v[o.field_offset..o.field_offset + 4].copy_from_slice(&(offset as u32).to_le_bytes());
        v
    }

    /// Build a 16-byte MonoType block (non-static).
    fn make_type_block(attrs: u16) -> Vec<u8> {
        let mut v = vec![0u8; 16];
        v[8..12].copy_from_slice(&(attrs as u32).to_le_bytes());
        v
    }

    /// Populate FakeMem with the seven required inventory fields at
    /// the given object-relative offsets, and the i32 values at those
    /// offsets inside an object blob. Returns (class_bytes, object_addr).
    fn populate_inventory(
        mem: &mut FakeMem,
        field_offsets: [(i32, i32); 7], // (offset, value) per FIELD_NAMES entry
        object_addr: u64,
    ) -> Vec<u8> {
        let fields_array_addr: u64 = 0x1_0000;
        let names_base: u64 = 0x2_0000;
        let types_base: u64 = 0x3_0000;

        let mut entry_blob = Vec::with_capacity(FIELD_NAMES.len() * MONO_CLASS_FIELD_SIZE);
        let mut object_blob = vec![0u8; 0x400];
        for (i, name) in FIELD_NAMES.iter().enumerate() {
            let name_ptr = names_base + (i as u64) * 0x40;
            let type_ptr = types_base + (i as u64) * 0x20;
            let (offset, value) = field_offsets[i];

            entry_blob.extend_from_slice(&make_field_entry(name_ptr, type_ptr, offset));

            let mut name_buf = name.as_bytes().to_vec();
            name_buf.push(0);
            mem.add(name_ptr, name_buf);
            mem.add(type_ptr, make_type_block(0));

            // Write the value into the object blob at the requested offset.
            let o = offset as usize;
            object_blob[o..o + 4].copy_from_slice(&value.to_le_bytes());
        }
        mem.add(fields_array_addr, entry_blob);
        mem.add(object_addr, object_blob);

        make_class_def(fields_array_addr, FIELD_NAMES.len() as u32)
    }

    #[test]
    fn read_inventory_returns_all_seven_values() -> Result<(), String> {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let object_addr: u64 = 0x4_0000;
        // Offsets chosen non-contiguous to catch offset-swapping bugs.
        let field_offsets: [(i32, i32); 7] = [
            (0x10, 42),     // wcCommon
            (0x14, 17),     // wcUncommon
            (0x18, 5),      // wcRare
            (0x1c, 2),      // wcMythic
            (0x20, 12_345), // gold
            (0x24, 3_000),  // gems
            (0x28, 250),    // vaultProgress
        ];
        let class_bytes = populate_inventory(&mut mem, field_offsets, object_addr);

        let inv = read_inventory(&offsets, &class_bytes, 0, object_addr, |a, l| {
            mem.read(a, l)
        })
        .ok_or("all seven fields should resolve")?;

        assert_eq!(
            inv,
            InventoryValues {
                wc_common: 42,
                wc_uncommon: 17,
                wc_rare: 5,
                wc_mythic: 2,
                gold: 12_345,
                gems: 3_000,
                vault_progress: 250,
            }
        );
        Ok(())
    }

    #[test]
    fn read_inventory_returns_none_when_a_field_is_missing() {
        // Build a class that exposes only 6 of the 7 fields — drop
        // vaultProgress. Resolver must fail and the whole call returns
        // None rather than a partial snapshot.
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let object_addr: u64 = 0x5_0000;

        let fields_array_addr: u64 = 0x1_0000;
        let names_base: u64 = 0x2_0000;
        let types_base: u64 = 0x3_0000;

        let mut entry_blob = Vec::new();
        let present_names = &FIELD_NAMES[..6]; // drop vaultProgress
        for (i, name) in present_names.iter().enumerate() {
            let name_ptr = names_base + (i as u64) * 0x40;
            let type_ptr = types_base + (i as u64) * 0x20;
            entry_blob.extend_from_slice(&make_field_entry(name_ptr, type_ptr, 0x10));
            let mut name_buf = name.as_bytes().to_vec();
            name_buf.push(0);
            mem.add(name_ptr, name_buf);
            mem.add(type_ptr, make_type_block(0));
        }
        mem.add(fields_array_addr, entry_blob);
        mem.add(object_addr, vec![0u8; 0x40]);

        let class_bytes = make_class_def(fields_array_addr, present_names.len() as u32);
        let inv = read_inventory(&offsets, &class_bytes, 0, object_addr, |a, l| {
            mem.read(a, l)
        });
        assert_eq!(inv, None);
    }

    #[test]
    fn read_inventory_rejects_static_field_by_design() {
        // A field flagged static cannot be at `object + offset`. Mark
        // gold as static and confirm the call fails rather than
        // reading from the wrong base.
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let object_addr: u64 = 0x6_0000;

        let fields_array_addr: u64 = 0x1_0000;
        let names_base: u64 = 0x2_0000;
        let types_base: u64 = 0x3_0000;

        let mut entry_blob = Vec::new();
        for (i, name) in FIELD_NAMES.iter().enumerate() {
            let name_ptr = names_base + (i as u64) * 0x40;
            let type_ptr = types_base + (i as u64) * 0x20;
            entry_blob.extend_from_slice(&make_field_entry(
                name_ptr,
                type_ptr,
                0x10 + i as i32 * 4,
            ));
            let mut name_buf = name.as_bytes().to_vec();
            name_buf.push(0);
            mem.add(name_ptr, name_buf);
            // `gold` (index 4) gets MONO_FIELD_ATTR_STATIC so it can't
            // be read off the object pointer.
            let attrs = if *name == "gold" {
                mono::MONO_FIELD_ATTR_STATIC
            } else {
                0
            };
            mem.add(type_ptr, make_type_block(attrs));
        }
        mem.add(fields_array_addr, entry_blob);
        mem.add(object_addr, vec![0u8; 0x40]);

        let class_bytes = make_class_def(fields_array_addr, FIELD_NAMES.len() as u32);
        let inv = read_inventory(&offsets, &class_bytes, 0, object_addr, |a, l| {
            mem.read(a, l)
        });
        assert_eq!(inv, None);
    }

    #[test]
    fn read_inventory_rejects_negative_field_offset() {
        // A field whose offset is -1 means "special static, not yet
        // assigned". Even if attrs aren't static-flagged, the walker
        // must not attempt an object-relative read.
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let object_addr: u64 = 0x7_0000;

        let fields_array_addr: u64 = 0x1_0000;
        let names_base: u64 = 0x2_0000;
        let types_base: u64 = 0x3_0000;

        let mut entry_blob = Vec::new();
        for (i, name) in FIELD_NAMES.iter().enumerate() {
            let name_ptr = names_base + (i as u64) * 0x40;
            let type_ptr = types_base + (i as u64) * 0x20;
            let offset = if *name == "gems" {
                -1
            } else {
                0x10 + i as i32 * 4
            };
            entry_blob.extend_from_slice(&make_field_entry(name_ptr, type_ptr, offset));
            let mut name_buf = name.as_bytes().to_vec();
            name_buf.push(0);
            mem.add(name_ptr, name_buf);
            mem.add(type_ptr, make_type_block(0));
        }
        mem.add(fields_array_addr, entry_blob);
        mem.add(object_addr, vec![0u8; 0x40]);

        let class_bytes = make_class_def(fields_array_addr, FIELD_NAMES.len() as u32);
        let inv = read_inventory(&offsets, &class_bytes, 0, object_addr, |a, l| {
            mem.read(a, l)
        });
        assert_eq!(inv, None);
    }

    #[test]
    fn field_names_constant_stays_in_struct_order() {
        // Guard the invariant read_inventory relies on: values[i] fills
        // the struct position corresponding to FIELD_NAMES[i].
        assert_eq!(FIELD_NAMES.len(), 7);
        assert_eq!(FIELD_NAMES[0], "wcCommon");
        assert_eq!(FIELD_NAMES[6], "vaultProgress");
    }
}
