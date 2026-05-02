//! Read MTGA's `ClientPlayerInventory.boosters` list.
//!
//! `ClientPlayerInventory.boosters` is a `List<ClientBoosterInfo>` at
//! instance offset `0x0010` of the inventory object. Each
//! `ClientBoosterInfo` element carries two 32-bit ints:
//!
//! ```text
//! +0x10  collationId : i32     // MTGA's internal booster-product id
//! +0x14  count       : i32     // unopened packs of that product
//! ```
//!
//! `collationId` matches the integer MTGA emits in `Player.log` under
//! `Changes[*].Boosters[].collationId` — same vocabulary on both
//! sides of the log/memory boundary.
//!
//! Verified 2026-05-02 against MTGA build timestamp
//! `Fri Apr 11 17:22:20 2025` — see
//! `mtga-duress/experiments/spikes/spike18_booster_inventory/FINDING.md`.

use super::field;
use super::list_t;
use super::mono::{self, MonoOffsets};

/// One booster row read from `ClientPlayerInventory.boosters`.
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub struct BoosterRow {
    pub collation_id: i32,
    pub count: i32,
}

/// Read `ClientPlayerInventory.boosters` into a `Vec<BoosterRow>`.
///
/// Resolves the `boosters` field on the inventory's class, follows
/// the pointer to the closed-generic `List<ClientBoosterInfo>`,
/// reads its `_size` and `_items`, then dereferences each element
/// pointer to read `(collation_id, count)` from the element's
/// runtime-class field offsets.
///
/// Returns an empty `Vec` when `boosters` is null, the list is
/// empty, or any element fails to resolve. Per the project's
/// "loud failure" rule for required reads, any *partial* failure
/// (one bad element among populated ones) collapses to empty
/// rather than emitting a half-truth.
pub fn read_boosters<F>(
    offsets: &MonoOffsets,
    inventory_class_bytes: &[u8],
    inventory_addr: u64,
    read_mem: F,
) -> Vec<BoosterRow>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let Some(list_addr) = read_pointer_field(
        offsets,
        inventory_class_bytes,
        inventory_addr,
        "boosters",
        &read_mem,
    ) else {
        return Vec::new();
    };

    let Some(list_class_bytes) = read_object_class_def(list_addr, &read_mem) else {
        return Vec::new();
    };

    let element_addrs = list_t::read_pointer_list(offsets, &list_class_bytes, list_addr, &read_mem);
    if element_addrs.is_empty() {
        return Vec::new();
    }

    let Some(elem_class_bytes) = read_object_class_def(element_addrs[0], &read_mem) else {
        return Vec::new();
    };

    let Some(collation_field) =
        field::find_field_by_name(offsets, &elem_class_bytes, "collationId", read_mem)
    else {
        return Vec::new();
    };
    let Some(count_field) =
        field::find_field_by_name(offsets, &elem_class_bytes, "count", read_mem)
    else {
        return Vec::new();
    };

    if collation_field.is_static
        || collation_field.offset < 0
        || count_field.is_static
        || count_field.offset < 0
    {
        return Vec::new();
    }

    let mut rows = Vec::with_capacity(element_addrs.len());
    for elem_addr in element_addrs {
        let Some(coll) = read_i32_at(elem_addr + collation_field.offset as u64, &read_mem) else {
            return Vec::new();
        };
        let Some(cnt) = read_i32_at(elem_addr + count_field.offset as u64, &read_mem) else {
            return Vec::new();
        };
        rows.push(BoosterRow {
            collation_id: coll,
            count: cnt,
        });
    }
    rows
}

use super::object::{
    read_instance_pointer as read_pointer_field,
    read_runtime_class_bytes as read_object_class_def,
};

fn read_i32_at<F>(addr: u64, read_mem: &F) -> Option<i32>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let bytes = read_mem(addr, 4)?;
    mono::read_u32(&bytes, 0, 0).map(|v| v as i32)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::walker::test_support::{make_class_def, make_type_block, FakeMem};

    fn make_field_entry(name_ptr: u64, type_ptr: u64, offset: i32) -> Vec<u8> {
        crate::walker::test_support::make_field_entry(name_ptr, type_ptr, 0, offset)
    }

    /// Wire up a minimal scenario: an inventory object with a `boosters`
    /// field at offset 0x10 pointing to a List<T> with `n` elements,
    /// each carrying given `(collation_id, count)` pairs.
    fn install_scenario(mem: &mut FakeMem, rows: &[(i32, i32)]) -> u64 {
        let inv_addr: u64 = 0x100_000;
        let inv_class_addr: u64 = 0x200_000;
        let inv_fields_addr: u64 = 0x210_000;
        let inv_name_addr: u64 = 0x220_000;
        let inv_type_addr: u64 = 0x230_000;

        let list_addr: u64 = 0x300_000;
        let list_class_addr: u64 = 0x400_000;
        let list_fields_addr: u64 = 0x410_000;
        let list_size_name: u64 = 0x420_000;
        let list_size_type: u64 = 0x430_000;
        let list_items_name: u64 = 0x440_000;
        let list_items_type: u64 = 0x450_000;

        let items_addr: u64 = 0x500_000;

        let elem_class_addr: u64 = 0x600_000;
        let elem_fields_addr: u64 = 0x610_000;
        let elem_name_coll: u64 = 0x620_000;
        let elem_type_coll: u64 = 0x630_000;
        let elem_name_count: u64 = 0x640_000;
        let elem_type_count: u64 = 0x650_000;

        let elem_base: u64 = 0x700_000; // each element gets 0x100 of stride

        // Inventory object: vtable @ 0x00 → inv_class_addr, boosters @ 0x10 → list_addr
        let mut inv_obj = vec![0u8; 0x40];
        let inv_vtable: u64 = 0x800_000;
        inv_obj[0..8].copy_from_slice(&inv_vtable.to_le_bytes());
        inv_obj[0x10..0x18].copy_from_slice(&list_addr.to_le_bytes());
        mem.add(inv_addr, inv_obj);
        mem.add(inv_vtable, inv_class_addr.to_le_bytes().to_vec());

        // Inventory class: one field, "boosters" at offset 0x10.
        mem.add(inv_class_addr, make_class_def(inv_fields_addr, 1));
        mem.add(inv_fields_addr, make_field_entry(inv_name_addr, inv_type_addr, 0x10));
        let mut nb = b"boosters".to_vec();
        nb.push(0);
        mem.add(inv_name_addr, nb);
        mem.add(inv_type_addr, make_type_block(0));

        // List object: vtable → list_class_addr, _items @ 0x10, _size @ 0x18
        let mut list_obj = vec![0u8; 0x40];
        let list_vtable: u64 = 0x810_000;
        list_obj[0..8].copy_from_slice(&list_vtable.to_le_bytes());
        list_obj[0x10..0x18].copy_from_slice(&items_addr.to_le_bytes());
        list_obj[0x18..0x1c].copy_from_slice(&(rows.len() as u32).to_le_bytes());
        mem.add(list_addr, list_obj);
        mem.add(list_vtable, list_class_addr.to_le_bytes().to_vec());

        // List class: 2 fields — _items @ 0x10, _size @ 0x18
        mem.add(list_class_addr, make_class_def(list_fields_addr, 2));
        let mut entries = Vec::new();
        entries.extend_from_slice(&make_field_entry(list_items_name, list_items_type, 0x10));
        entries.extend_from_slice(&make_field_entry(list_size_name, list_size_type, 0x18));
        mem.add(list_fields_addr, entries);
        let mut items_nb = b"_items".to_vec();
        items_nb.push(0);
        mem.add(list_items_name, items_nb);
        mem.add(list_items_type, make_type_block(0));
        let mut size_nb = b"_size".to_vec();
        size_nb.push(0);
        mem.add(list_size_name, size_nb);
        mem.add(list_size_type, make_type_block(0));

        // MonoArray (`_items`) header + element pointers at 0x20 onward.
        let mut arr = vec![0u8; 0x20 + rows.len() * 8];
        for (i, _) in rows.iter().enumerate() {
            let elem_addr = elem_base + (i as u64) * 0x100;
            arr[0x20 + i * 8..0x20 + i * 8 + 8].copy_from_slice(&elem_addr.to_le_bytes());
        }
        mem.add(items_addr, arr);

        // Element objects + element class.
        let elem_vtable: u64 = 0x820_000;
        for (i, (collation, count)) in rows.iter().enumerate() {
            let elem_addr = elem_base + (i as u64) * 0x100;
            let mut obj = vec![0u8; 0x40];
            obj[0..8].copy_from_slice(&elem_vtable.to_le_bytes());
            obj[0x10..0x14].copy_from_slice(&(*collation as u32).to_le_bytes());
            obj[0x14..0x18].copy_from_slice(&(*count as u32).to_le_bytes());
            mem.add(elem_addr, obj);
        }
        mem.add(elem_vtable, elem_class_addr.to_le_bytes().to_vec());

        // Element class: 2 fields — collationId @ 0x10, count @ 0x14
        mem.add(elem_class_addr, make_class_def(elem_fields_addr, 2));
        let mut entries = Vec::new();
        entries.extend_from_slice(&make_field_entry(elem_name_coll, elem_type_coll, 0x10));
        entries.extend_from_slice(&make_field_entry(elem_name_count, elem_type_count, 0x14));
        mem.add(elem_fields_addr, entries);
        let mut coll_nb = b"collationId".to_vec();
        coll_nb.push(0);
        mem.add(elem_name_coll, coll_nb);
        mem.add(elem_type_coll, make_type_block(0));
        let mut count_nb = b"count".to_vec();
        count_nb.push(0);
        mem.add(elem_name_count, count_nb);
        mem.add(elem_type_count, make_type_block(0));

        inv_addr
    }

    fn read_inventory_class_bytes(mem: &FakeMem, inv_addr: u64) -> Option<Vec<u8>> {
        let vtable_buf = mem.read(inv_addr, 8)?;
        let vtable_addr = u64::from_le_bytes(vtable_buf.get(..8)?.try_into().ok()?);
        let klass_buf = mem.read(vtable_addr, 8)?;
        let klass_addr = u64::from_le_bytes(klass_buf.get(..8)?.try_into().ok()?);
        mem.read(klass_addr, mono::CLASS_DEF_BLOB_LEN)
    }

    #[test]
    fn read_boosters_returns_all_elements() -> Result<(), String> {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let inv_addr = install_scenario(&mut mem, &[(100_060, 99), (100_345, 1)]);
        let inv_class_bytes =
            read_inventory_class_bytes(&mem, inv_addr).ok_or("read inv class bytes")?;

        let rows = read_boosters(&offsets, &inv_class_bytes, inv_addr, |a, l| mem.read(a, l));

        assert_eq!(
            rows,
            vec![
                BoosterRow {
                    collation_id: 100_060,
                    count: 99
                },
                BoosterRow {
                    collation_id: 100_345,
                    count: 1
                },
            ]
        );
        Ok(())
    }

    #[test]
    fn read_boosters_returns_empty_for_null_pointer_field() -> Result<(), String> {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let inv_addr = install_scenario(&mut mem, &[]);

        // Overwrite the boosters slot with NULL.
        let mut zeroed = mem.read(inv_addr, 0x40).ok_or("read inv obj")?;
        zeroed[0x10..0x18].copy_from_slice(&0u64.to_le_bytes());
        mem.replace(inv_addr, zeroed);

        let inv_class_bytes =
            read_inventory_class_bytes(&mem, inv_addr).ok_or("read inv class bytes")?;
        let rows = read_boosters(&offsets, &inv_class_bytes, inv_addr, |a, l| mem.read(a, l));
        assert!(rows.is_empty());
        Ok(())
    }

    #[test]
    fn read_boosters_returns_empty_when_list_is_empty() -> Result<(), String> {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let inv_addr = install_scenario(&mut mem, &[]);
        let inv_class_bytes =
            read_inventory_class_bytes(&mem, inv_addr).ok_or("read inv class bytes")?;

        let rows = read_boosters(&offsets, &inv_class_bytes, inv_addr, |a, l| mem.read(a, l));
        assert!(rows.is_empty());
        Ok(())
    }

    #[test]
    fn read_boosters_handles_single_element_list() -> Result<(), String> {
        // Boundary case: list contains exactly one ClientBoosterInfo.
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let inv_addr = install_scenario(&mut mem, &[(100_001, 7)]);
        let inv_class_bytes =
            read_inventory_class_bytes(&mem, inv_addr).ok_or("read inv class bytes")?;

        let rows = read_boosters(&offsets, &inv_class_bytes, inv_addr, |a, l| mem.read(a, l));
        assert_eq!(
            rows,
            vec![BoosterRow {
                collation_id: 100_001,
                count: 7
            }]
        );
        Ok(())
    }

    #[test]
    fn read_boosters_returns_empty_when_element_class_lacks_collation_field() -> Result<(), String>
    {
        // The "loud failure" rule per module doc: any partial failure
        // collapses to empty. Drop the `collationId` field name on the
        // element class; the walker should refuse to emit a half-truth
        // even for a populated list.
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let inv_addr = install_scenario(&mut mem, &[(100_060, 99)]);
        let inv_class_bytes =
            read_inventory_class_bytes(&mem, inv_addr).ok_or("read inv class bytes")?;

        // Replace the element-class fields name string ("collationId")
        // with a name that find_by_name will not match. The element
        // class lives at 0x600_000 with a name pointer at 0x620_000.
        let bogus_name = b"notCollationId\0".to_vec();
        mem.replace(0x620_000, bogus_name);

        let rows = read_boosters(&offsets, &inv_class_bytes, inv_addr, |a, l| mem.read(a, l));
        assert!(
            rows.is_empty(),
            "loud-failure rule: any partial failure collapses to empty"
        );
        Ok(())
    }
}
