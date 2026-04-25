//! Pointer-chain orchestrator — compose the walker primitives into
//! end-to-end reads of MTGA's inventory state.
//!
//! The chain from the `mono-memory-reader` skill:
//!
//! ```text
//! PAPA singleton
//!   <InventoryManager>k__BackingField
//!     _inventoryServiceWrapper  ← innermost composed level exposed today
//!       <Cards>k__BackingField   -> Dictionary<int,int>
//!       m_inventory              -> ClientPlayerInventory { 7 fields }
//! ```
//!
//! This module currently exposes the innermost composition:
//! [`from_service_wrapper`] assumes the caller has already resolved
//! the `InventoryServiceWrapper` object address (e.g. via a future
//! static-field read from the PAPA singleton) plus the class bytes
//! for the three classes whose fields we traverse.
//!
//! Outer layers (static field via VTable, class-by-name lookup
//! within a `MonoImage`) are the next modules in the roadmap —
//! adding them on top of this orchestrator is append-only.

use super::dict::{self, DictEntry};
use super::field::{self, ResolvedField};
use super::inventory::{self, InventoryValues};
use super::mono::{self, MonoOffsets};

/// Combined result of a full walk.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WalkResult {
    /// Used entries from the `Cards` dictionary.
    pub entries: Vec<DictEntry>,
    /// Wildcards / currencies / vault progress.
    pub inventory: InventoryValues,
}

/// Walk from a resolved `InventoryServiceWrapper` object.
///
/// Required inputs:
/// - `service_wrapper_addr` — object address in the target process.
/// - `service_wrapper_class_bytes` — bytes of the wrapper's
///   `MonoClassDef` (covers `MonoClass.fields` @ `0x98` and
///   `MonoClassDef.field_count` @ `0x100`).
/// - `dictionary_class_bytes` — bytes of the `Dictionary<int,int>`
///   class (for resolving `_entries`).
/// - `inventory_class_bytes` — bytes of `ClientPlayerInventory`.
/// - `read_mem(addr, len)` — remote-memory reader closure.
///
/// Returns `None` on any miss (unresolved field, null pointer,
/// truncated read, dict cap exceeded, etc.). The walk is
/// all-or-nothing — no partial snapshots.
pub fn from_service_wrapper<F>(
    offsets: &MonoOffsets,
    service_wrapper_addr: u64,
    service_wrapper_class_bytes: &[u8],
    dictionary_class_bytes: &[u8],
    inventory_class_bytes: &[u8],
    read_mem: F,
) -> Option<WalkResult>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    // Cards → Dictionary<int,int> object
    let cards_dict_addr = read_instance_pointer(
        offsets,
        service_wrapper_class_bytes,
        0,
        service_wrapper_addr,
        "Cards",
        &read_mem,
    )?;

    // Dictionary<int,int>._entries → MonoArray<Entry>
    let entries_array_addr = read_instance_pointer(
        offsets,
        dictionary_class_bytes,
        0,
        cards_dict_addr,
        "_entries",
        &read_mem,
    )?;
    let entries = dict::read_int_int_entries(offsets, entries_array_addr, &read_mem)?;

    // m_inventory → ClientPlayerInventory object
    let inv_addr = read_instance_pointer(
        offsets,
        service_wrapper_class_bytes,
        0,
        service_wrapper_addr,
        "m_inventory",
        &read_mem,
    )?;
    let inventory_values =
        inventory::read_inventory(offsets, inventory_class_bytes, 0, inv_addr, &read_mem)?;

    Some(WalkResult {
        entries,
        inventory: inventory_values,
    })
}

/// Resolve `field_name` on the class at `class_base` inside
/// `class_bytes`, then read a pointer at `object_addr + field.offset`.
///
/// Rejects static fields, negative offsets, and null pointers —
/// those would indicate the walker is on a wrong path or hit an
/// uninitialised field.
fn read_instance_pointer<F>(
    offsets: &MonoOffsets,
    class_bytes: &[u8],
    class_base: usize,
    object_addr: u64,
    field_name: &str,
    read_mem: &F,
) -> Option<u64>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let resolved: ResolvedField =
        field::find_by_name(offsets, class_bytes, class_base, field_name, read_mem)?;
    if resolved.is_static || resolved.offset < 0 {
        return None;
    }
    let addr = object_addr.checked_add(resolved.offset as u64)?;
    let bytes = read_mem(addr, 8)?;
    let ptr = mono::read_u64(&bytes, 0, 0)?;
    if ptr == 0 {
        return None;
    }
    Some(ptr)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::walker::inventory::FIELD_NAMES;
    use crate::walker::mono::{DICT_INT_INT_ENTRY_SIZE, MONO_CLASS_FIELD_SIZE};

    /// FakeMem — simple (base, bytes) pair list.
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

    /// Write a 32-byte MonoClassField entry (non-static).
    fn make_field_entry(name_ptr: u64, type_ptr: u64, offset: i32) -> Vec<u8> {
        let o = MonoOffsets::mtga_default();
        let mut v = vec![0u8; MONO_CLASS_FIELD_SIZE];
        v[o.field_type..o.field_type + 8].copy_from_slice(&type_ptr.to_le_bytes());
        v[o.field_name..o.field_name + 8].copy_from_slice(&name_ptr.to_le_bytes());
        v[o.field_offset..o.field_offset + 4].copy_from_slice(&(offset as u32).to_le_bytes());
        v
    }

    /// 16-byte MonoType block; low 16 bits of bitfield word = attrs.
    fn make_type_block(attrs: u16) -> Vec<u8> {
        let mut v = vec![0u8; 16];
        v[8..12].copy_from_slice(&(attrs as u32).to_le_bytes());
        v
    }

    /// MonoClassDef header: class.fields @ 0x98, class_def.field_count @ 0x100.
    fn make_class_def(fields_ptr: u64, field_count: u32) -> Vec<u8> {
        let offsets = MonoOffsets::mtga_default();
        let mut buf = vec![0u8; 0x110];
        buf[offsets.class_fields..offsets.class_fields + 8]
            .copy_from_slice(&fields_ptr.to_le_bytes());
        buf[offsets.class_def_field_count..offsets.class_def_field_count + 4]
            .copy_from_slice(&field_count.to_le_bytes());
        buf
    }

    /// Install a class with named fields into FakeMem at `fields_addr`,
    /// `names_base`, `types_base`. Returns the class_bytes blob.
    fn install_class(
        mem: &mut FakeMem,
        fields_addr: u64,
        names_base: u64,
        types_base: u64,
        specs: &[(&str, i32)],
    ) -> Vec<u8> {
        let mut blob = Vec::with_capacity(specs.len() * MONO_CLASS_FIELD_SIZE);
        for (i, (name, offset)) in specs.iter().enumerate() {
            let name_ptr = names_base + (i as u64) * 0x80;
            let type_ptr = types_base + (i as u64) * 0x40;
            blob.extend_from_slice(&make_field_entry(name_ptr, type_ptr, *offset));
            let mut nbuf = name.as_bytes().to_vec();
            nbuf.push(0);
            mem.add(name_ptr, nbuf);
            mem.add(type_ptr, make_type_block(0));
        }
        mem.add(fields_addr, blob);
        make_class_def(fields_addr, specs.len() as u32)
    }

    /// MonoArray<Entry> header + used-slot blob at `array_addr`.
    fn install_dict_array(mem: &mut FakeMem, array_addr: u64, entries: &[(i32, i32)]) {
        let o = MonoOffsets::mtga_default();
        let capacity = entries.len() as u64;
        let mut header = vec![0u8; o.array_vector];
        header[o.array_max_length..o.array_max_length + 8].copy_from_slice(&capacity.to_le_bytes());
        mem.add(array_addr, header);

        let vector_addr = array_addr + o.array_vector as u64;
        let mut blob = Vec::with_capacity(entries.len() * DICT_INT_INT_ENTRY_SIZE);
        for (key, value) in entries {
            // used entry: hashCode = key & 0x7FFFFFFF
            blob.extend_from_slice(&(key & 0x7FFF_FFFF).to_le_bytes());
            blob.extend_from_slice(&(-1i32).to_le_bytes()); // next
            blob.extend_from_slice(&key.to_le_bytes());
            blob.extend_from_slice(&value.to_le_bytes());
        }
        mem.add(vector_addr, blob);
    }

    /// Install a ClientPlayerInventory object + class whose 7 fields
    /// each sit at `(0x10 + i*4, value)`. Returns (obj_addr, class_bytes).
    fn install_inventory(mem: &mut FakeMem, obj_addr: u64, values: [i32; 7]) -> Vec<u8> {
        // Class
        let fields_addr: u64 = 0x5_0000;
        let names_base: u64 = 0x5_1000;
        let types_base: u64 = 0x5_2000;
        let specs: Vec<(&str, i32)> = FIELD_NAMES
            .iter()
            .enumerate()
            .map(|(i, n)| (*n, 0x10 + i as i32 * 4))
            .collect();
        let class_bytes = install_class(mem, fields_addr, names_base, types_base, &specs);

        // Object: 0x40-byte blob with the 7 values
        let mut obj = vec![0u8; 0x40];
        for (i, v) in values.iter().enumerate() {
            let off = 0x10 + i * 4;
            obj[off..off + 4].copy_from_slice(&v.to_le_bytes());
        }
        mem.add(obj_addr, obj);

        class_bytes
    }

    #[test]
    fn end_to_end_walk_returns_both_halves() -> Result<(), String> {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();

        // --- Dictionary<int,int> class: one field, `_entries` at 0x18
        let dict_fields_addr: u64 = 0x2_0000;
        let dict_class_bytes = install_class(
            &mut mem,
            dict_fields_addr,
            0x2_1000,
            0x2_2000,
            &[("_entries", 0x18)],
        );

        // --- Dictionary object & array
        let dict_obj_addr: u64 = 0x3_0000;
        let entries_array_addr: u64 = 0x3_1000;
        // Dictionary object: pointer to entries array at offset 0x18
        let mut dict_obj = vec![0u8; 0x40];
        dict_obj[0x18..0x18 + 8].copy_from_slice(&entries_array_addr.to_le_bytes());
        mem.add(dict_obj_addr, dict_obj);
        install_dict_array(
            &mut mem,
            entries_array_addr,
            &[(74116, 1), (32388, 4), (106_219, 3)],
        );

        // --- Inventory object & class
        let inv_obj_addr: u64 = 0x4_0000;
        let inv_class_bytes =
            install_inventory(&mut mem, inv_obj_addr, [42, 17, 5, 2, 12_345, 3_000, 250]);

        // --- InventoryServiceWrapper: Cards (→ dict_obj) at 0x10,
        //     m_inventory (→ inv_obj) at 0x20.
        let sw_fields_addr: u64 = 0x6_0000;
        let sw_class_bytes = install_class(
            &mut mem,
            sw_fields_addr,
            0x6_1000,
            0x6_2000,
            &[("Cards", 0x10), ("m_inventory", 0x20)],
        );
        let sw_addr: u64 = 0x7_0000;
        let mut sw_obj = vec![0u8; 0x40];
        sw_obj[0x10..0x10 + 8].copy_from_slice(&dict_obj_addr.to_le_bytes());
        sw_obj[0x20..0x20 + 8].copy_from_slice(&inv_obj_addr.to_le_bytes());
        mem.add(sw_addr, sw_obj);

        let result = from_service_wrapper(
            &offsets,
            sw_addr,
            &sw_class_bytes,
            &dict_class_bytes,
            &inv_class_bytes,
            |a, l| mem.read(a, l),
        )
        .ok_or("walk should succeed")?;

        assert_eq!(result.entries.len(), 3);
        assert!(result
            .entries
            .iter()
            .any(|e| e.key == 74116 && e.value == 1));
        assert!(result
            .entries
            .iter()
            .any(|e| e.key == 32388 && e.value == 4));
        assert_eq!(result.inventory.wc_common, 42);
        assert_eq!(result.inventory.gold, 12_345);
        assert_eq!(result.inventory.vault_progress, 250);
        Ok(())
    }

    #[test]
    fn walk_resolves_cards_via_backing_field_name() -> Result<(), String> {
        // If the service wrapper exposes the BACKING form rather than
        // a literal `Cards` field, field::find_by_name's second pass
        // must still resolve it.
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();

        let dict_class_bytes = install_class(
            &mut mem,
            0x2_0000,
            0x2_1000,
            0x2_2000,
            &[("_entries", 0x18)],
        );

        let dict_obj_addr: u64 = 0x3_0000;
        let entries_array_addr: u64 = 0x3_1000;
        let mut dict_obj = vec![0u8; 0x40];
        dict_obj[0x18..0x18 + 8].copy_from_slice(&entries_array_addr.to_le_bytes());
        mem.add(dict_obj_addr, dict_obj);
        install_dict_array(&mut mem, entries_array_addr, &[(7, 1)]);

        let inv_obj_addr: u64 = 0x4_0000;
        let inv_class_bytes = install_inventory(&mut mem, inv_obj_addr, [1, 1, 1, 1, 1, 1, 1]);

        // Wrapper class exposes <Cards>k__BackingField (not literal
        // "Cards") for the dictionary reference.
        let sw_class_bytes = install_class(
            &mut mem,
            0x6_0000,
            0x6_1000,
            0x6_2000,
            &[("<Cards>k__BackingField", 0x10), ("m_inventory", 0x20)],
        );
        let sw_addr: u64 = 0x7_0000;
        let mut sw_obj = vec![0u8; 0x40];
        sw_obj[0x10..0x10 + 8].copy_from_slice(&dict_obj_addr.to_le_bytes());
        sw_obj[0x20..0x20 + 8].copy_from_slice(&inv_obj_addr.to_le_bytes());
        mem.add(sw_addr, sw_obj);

        let result = from_service_wrapper(
            &offsets,
            sw_addr,
            &sw_class_bytes,
            &dict_class_bytes,
            &inv_class_bytes,
            |a, l| mem.read(a, l),
        )
        .ok_or("walk should succeed with backing-field Cards")?;

        assert_eq!(result.entries, vec![DictEntry { key: 7, value: 1 }]);
        Ok(())
    }

    #[test]
    fn walk_returns_none_when_cards_pointer_is_null() {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();

        let dict_class_bytes = install_class(
            &mut mem,
            0x2_0000,
            0x2_1000,
            0x2_2000,
            &[("_entries", 0x18)],
        );
        let inv_obj_addr: u64 = 0x4_0000;
        let inv_class_bytes = install_inventory(&mut mem, inv_obj_addr, [1, 1, 1, 1, 1, 1, 1]);
        let sw_class_bytes = install_class(
            &mut mem,
            0x6_0000,
            0x6_1000,
            0x6_2000,
            &[("Cards", 0x10), ("m_inventory", 0x20)],
        );
        let sw_addr: u64 = 0x7_0000;
        let mut sw_obj = vec![0u8; 0x40];
        // Cards pointer = 0 — uninitialised
        sw_obj[0x20..0x20 + 8].copy_from_slice(&inv_obj_addr.to_le_bytes());
        mem.add(sw_addr, sw_obj);

        assert_eq!(
            from_service_wrapper(
                &offsets,
                sw_addr,
                &sw_class_bytes,
                &dict_class_bytes,
                &inv_class_bytes,
                |a, l| mem.read(a, l),
            ),
            None
        );
    }

    #[test]
    fn walk_returns_none_when_entries_field_missing_from_dict_class() {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();

        // Dictionary class is missing _entries — pretend the key field
        // is named wrong. Walker must fail cleanly.
        let dict_class_bytes = install_class(
            &mut mem,
            0x2_0000,
            0x2_1000,
            0x2_2000,
            &[("not_entries", 0x18)],
        );

        let dict_obj_addr: u64 = 0x3_0000;
        mem.add(dict_obj_addr, vec![0u8; 0x40]);

        let inv_obj_addr: u64 = 0x4_0000;
        let inv_class_bytes = install_inventory(&mut mem, inv_obj_addr, [1, 1, 1, 1, 1, 1, 1]);

        let sw_class_bytes = install_class(
            &mut mem,
            0x6_0000,
            0x6_1000,
            0x6_2000,
            &[("Cards", 0x10), ("m_inventory", 0x20)],
        );
        let sw_addr: u64 = 0x7_0000;
        let mut sw_obj = vec![0u8; 0x40];
        sw_obj[0x10..0x10 + 8].copy_from_slice(&dict_obj_addr.to_le_bytes());
        sw_obj[0x20..0x20 + 8].copy_from_slice(&inv_obj_addr.to_le_bytes());
        mem.add(sw_addr, sw_obj);

        assert_eq!(
            from_service_wrapper(
                &offsets,
                sw_addr,
                &sw_class_bytes,
                &dict_class_bytes,
                &inv_class_bytes,
                |a, l| mem.read(a, l),
            ),
            None
        );
    }
}
