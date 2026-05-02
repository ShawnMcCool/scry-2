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
//! | `vaultProgress` | progress toward the next vault opening (0–100 %) |
//!
//! Per spike 5 every one of these is a literal field name (no
//! `<...>k__BackingField` decoration), so `field::find_field_by_name`
//! resolves each with its exact-match pass.
//!
//! Wildcard counts and currencies are 32-bit little-endian integers.
//! `vaultProgress` is a **`System.Double`** (8 bytes) holding the
//! percentage as a float (e.g. `30.1` for "30.1 % of the way to the
//! next vault opening"); the 4-byte gap between it and the previous
//! `wcTrackPosition` field at offset `0x68` is alignment padding the
//! C# compiler inserts ahead of the 8-byte aligned double.
//! Confirmed against MTGA's live UI on 2026-04-25.

use super::instance_field;
use super::mono::MonoOffsets;

/// Snapshot of one `ClientPlayerInventory` read.
///
/// `vault_progress` is the live 0–100 percentage as a `f64` —
/// matches MTGA's `System.Double` field. We don't impl `Eq` on the
/// struct because of the float field, but `PartialEq` + `Clone` +
/// `Copy` are still useful for tests and snapshot equality on the
/// integer fields.
#[derive(Copy, Clone, Debug, PartialEq)]
pub struct InventoryValues {
    pub wc_common: i32,
    pub wc_uncommon: i32,
    pub wc_rare: i32,
    pub wc_mythic: i32,
    pub gold: i32,
    pub gems: i32,
    pub vault_progress: f64,
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
    object_remote_addr: u64,
    read_mem: F,
) -> Option<InventoryValues>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let mut values = [0i32; 6];
    for (i, name) in FIELD_NAMES.iter().take(6).enumerate() {
        values[i] = instance_field::read_instance_i32(
            offsets,
            class_bytes,
            object_remote_addr,
            name,
            &read_mem,
        )?;
    }
    let vault_progress = instance_field::read_instance_f64(
        offsets,
        class_bytes,
        object_remote_addr,
        "vaultProgress",
        &read_mem,
    )?;
    Some(InventoryValues {
        wc_common: values[0],
        wc_uncommon: values[1],
        wc_rare: values[2],
        wc_mythic: values[3],
        gold: values[4],
        gems: values[5],
        vault_progress,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::walker::mono::{self, MONO_CLASS_FIELD_SIZE};
    use crate::walker::test_support::{make_class_def, make_type_block, FakeMem};

    /// Local helper: 3-arg field-entry shape (no parent_ptr — tests
    /// here don't read it). Wraps the canonical 4-arg builder.
    fn make_field_entry(name_ptr: u64, type_ptr: u64, offset: i32) -> Vec<u8> {
        crate::walker::test_support::make_field_entry(name_ptr, type_ptr, 0, offset)
    }

    /// Populate FakeMem with the seven required inventory fields at
    /// the given object-relative offsets. The first six values are
    /// 32-bit ints; `vaultProgress` is a 64-bit double. Returns the
    /// class_bytes blob the caller passes to `read_inventory`.
    fn populate_inventory(
        mem: &mut FakeMem,
        int_field_offsets: [(i32, i32); 6], // (offset, value) for first 6 fields
        vault_progress_offset: i32,
        vault_progress_value: f64,
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

            let offset = if i < 6 {
                int_field_offsets[i].0
            } else {
                vault_progress_offset
            };

            entry_blob.extend_from_slice(&make_field_entry(name_ptr, type_ptr, offset));

            let mut name_buf = name.as_bytes().to_vec();
            name_buf.push(0);
            mem.add(name_ptr, name_buf);
            mem.add(type_ptr, make_type_block(0));

            // Write the value into the object blob.
            let o = offset as usize;
            if i < 6 {
                let value = int_field_offsets[i].1;
                object_blob[o..o + 4].copy_from_slice(&value.to_le_bytes());
            } else {
                object_blob[o..o + 8].copy_from_slice(&vault_progress_value.to_bits().to_le_bytes());
            }
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
        let int_field_offsets: [(i32, i32); 6] = [
            (0x10, 42),     // wcCommon
            (0x14, 17),     // wcUncommon
            (0x18, 5),      // wcRare
            (0x1c, 2),      // wcMythic
            (0x20, 12_345), // gold
            (0x24, 3_000),  // gems
        ];
        let class_bytes =
            populate_inventory(&mut mem, int_field_offsets, 0x30, 30.1, object_addr);

        let inv = read_inventory(&offsets, &class_bytes, object_addr, |a, l| {
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
                vault_progress: 30.1,
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
        let inv = read_inventory(&offsets, &class_bytes, object_addr, |a, l| {
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
        let inv = read_inventory(&offsets, &class_bytes, object_addr, |a, l| {
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
        let inv = read_inventory(&offsets, &class_bytes, object_addr, |a, l| {
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
