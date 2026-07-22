//! Drill `BaseCardHolder._previousLayoutData : List<CardLayoutData>`
//! to extract revealed-card arena_ids for non-battlefield zones (hand,
//! graveyard, exile).
//!
//! Each `CardLayoutData` has:
//!   - `Card : BaseCDC`            — the card display object
//!   - `IsVisibleInLayout : bool`  — true iff rendered in this layout
//!
//! The "is revealed" filter is: the card's `BaseGrpId` (arena_id)
//! resolves to a nonzero value. MTGA never populates `BaseGrpId` for a
//! card it hasn't shown the local client's identity, so a resolved
//! nonzero id is the authoritative signal. `IsVisibleInLayout` is
//! checked first as a cheap pre-filter but is not sufficient on its
//! own — it is true for every card occupying a rendered slot,
//! including an opponent's face-down hand cards, not just revealed
//! ones. (`CardLayoutData` has no `FaceDownState` field in current
//! MTGA builds — verified live via `walker_debug_class_fields` on
//! 2026-07-21 — so an earlier version of this filter that checked it
//! always silently fell through to "revealed".)
//!
//! This naturally includes the local player's full hand (always
//! visible to themselves), only the Thoughtseize/Duress-revealed
//! entries in the opponent's hand, and every face-up entry in
//! graveyard / exile.

use super::card_holder;
use super::field;
use super::limits;
use super::list_t;
use super::mono::{self, MonoOffsets};
use super::object;

/// Read every revealed card's arena_id from a non-battlefield holder.
///
/// Returns the arena_ids in `_previousLayoutData` order. Empty `Vec`
/// when the chain is reachable but no entries pass the filter; `None`
/// only on structural read failure.
pub fn read_revealed_arena_ids<F>(
    offsets: &MonoOffsets,
    holder_addr: u64,
    read_mem: F,
) -> Option<Vec<i32>>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let holder_class_bytes = object::read_runtime_class_bytes(holder_addr, &read_mem)?;

    let list_field = field::find_field_by_name_in_chain(
        offsets,
        &holder_class_bytes,
        "_previousLayoutData",
        read_mem,
    )?;
    if list_field.is_static {
        return None;
    }

    let list_addr = read_pointer_at(
        holder_addr.checked_add(list_field.offset as u64)?,
        &read_mem,
    )?;
    if list_addr == 0 {
        return Some(Vec::new());
    }

    let list_class_bytes = object::read_runtime_class_bytes(list_addr, &read_mem)?;
    let entry_pointers =
        list_t::read_pointer_list(offsets, &list_class_bytes, list_addr, &read_mem);

    let mut arena_ids = Vec::with_capacity(entry_pointers.len().min(limits::MAX_LIST_ELEMENTS));
    for entry_addr in entry_pointers.into_iter().take(limits::MAX_LIST_ELEMENTS) {
        if entry_addr == 0 {
            continue;
        }
        if let Some(arena_id) =
            arena_id_for_layout_entry_if_revealed(offsets, entry_addr, &read_mem)
        {
            arena_ids.push(arena_id);
        }
    }

    Some(arena_ids)
}

/// Read one `CardLayoutData` and return its `Card`'s arena_id only if
/// the card's identity has actually been resolved client-side.
///
/// `IsVisibleInLayout` gates out entries not currently rendered in
/// this layout. The authoritative "was this genuinely revealed to
/// us" signal is `BaseGrpId` itself: MTGA never populates it for a
/// card it hasn't shown the local client (see module doc). An earlier
/// version of this filter also checked `CardLayoutData.FaceDownState`
/// — verified live via `walker_debug_class_fields("CardLayoutData")`
/// on 2026-07-21 that no such field exists on that class in current
/// MTGA builds, so the check always silently defaulted to "revealed"
/// and let every un-revealed opponent hand card through with
/// `arena_id == 0`.
fn arena_id_for_layout_entry_if_revealed<F>(
    offsets: &MonoOffsets,
    entry_addr: u64,
    read_mem: &F,
) -> Option<i32>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let entry_class_bytes = object::read_runtime_class_bytes(entry_addr, read_mem)?;

    if !is_visible_in_layout(offsets, &entry_class_bytes, entry_addr, read_mem) {
        return None;
    }

    let card_field =
        field::find_field_by_name_in_chain(offsets, &entry_class_bytes, "Card", *read_mem)?;
    if card_field.is_static {
        return None;
    }
    let card_addr = read_pointer_at(entry_addr.checked_add(card_field.offset as u64)?, read_mem)?;

    match card_holder::arena_id_for_cdc(offsets, card_addr, read_mem) {
        Some(arena_id) if arena_id != 0 => Some(arena_id),
        _ => None,
    }
}

/// True when `IsVisibleInLayout` is set. Defensive default: unreadable
/// → assume visible. This alone does not mean "revealed" — see
/// [`arena_id_for_layout_entry_if_revealed`] for the authoritative
/// check.
fn is_visible_in_layout<F>(
    offsets: &MonoOffsets,
    entry_class_bytes: &[u8],
    entry_addr: u64,
    read_mem: &F,
) -> bool
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    match field::find_field_by_name_in_chain(
        offsets,
        entry_class_bytes,
        "IsVisibleInLayout",
        *read_mem,
    ) {
        Some(f) if !f.is_static => match entry_addr.checked_add(f.offset as u64) {
            Some(read_addr) => match read_mem(read_addr, 1) {
                Some(bytes) if !bytes.is_empty() => bytes[0] != 0,
                _ => true, // unreadable → assume visible
            },
            None => true, // address overflow → assume visible
        },
        _ => true,
    }
}

fn read_pointer_at<F>(addr: u64, read_mem: &F) -> Option<u64>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let bytes = read_mem(addr, 8)?;
    mono::read_u64(&bytes, 0, 0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::walker::test_support::FakeMem;

    #[test]
    fn read_revealed_arena_ids_returns_none_when_holder_class_unreadable() {
        let mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();
        let result = read_revealed_arena_ids(&offsets, 0xdead_beef, |a, l| mem.read(a, l));
        assert_eq!(result, None);
    }

    use crate::walker::mono::MONO_CLASS_FIELD_SIZE;
    use crate::walker::test_support::{
        make_class_def_with_parent, make_field_entry, make_type_block,
    };

    /// Build a class declaring (name, offset) fields. Non-static, all on
    /// the own class (no parent). Returns the class-def blob.
    fn build_flat_class(
        mem: &mut FakeMem,
        fields_base: u64,
        names_base: u64,
        types_base: u64,
        fields: &[(&str, i32)],
    ) -> Vec<u8> {
        let mut entry_blob = Vec::with_capacity(fields.len() * MONO_CLASS_FIELD_SIZE);
        for (i, (name, offset)) in fields.iter().enumerate() {
            let np = names_base + (i as u64) * 0x80;
            let tp = types_base + (i as u64) * 0x20;
            entry_blob.extend_from_slice(&make_field_entry(np, tp, 0, *offset));
            let mut name_buf = name.as_bytes().to_vec();
            name_buf.push(0);
            mem.add(np, name_buf);
            mem.add(tp, make_type_block(0));
        }
        mem.add(fields_base, entry_blob);
        make_class_def_with_parent(fields_base, fields.len() as u32, 0)
    }

    /// Install an object whose vtable.klass points at `class_addr`.
    fn install_object(
        mem: &mut FakeMem,
        obj_addr: u64,
        payload_size: usize,
        vtable_addr: u64,
        class_addr: u64,
        class_bytes: &[u8],
        stamps: &[(i32, &[u8])],
    ) {
        let mut payload = vec![0u8; payload_size.max(0x10)];
        payload[0..8].copy_from_slice(&vtable_addr.to_le_bytes());
        for (off, bytes) in stamps {
            let off = *off as usize;
            payload[off..off + bytes.len()].copy_from_slice(bytes);
        }
        mem.add(obj_addr, payload);
        let mut vt = vec![0u8; 0x50];
        vt[0..8].copy_from_slice(&class_addr.to_le_bytes());
        mem.add(vtable_addr, vt);
        mem.add(class_addr, class_bytes.to_vec());
    }

    #[test]
    fn is_visible_in_layout_true_when_flag_set() {
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();

        let class_addr = 0x100_0000;
        let class_bytes = build_flat_class(
            &mut mem,
            0x101_0000,
            0x102_0000,
            0x103_0000,
            &[("IsVisibleInLayout", 0x10)],
        );
        let entry_addr = 0x110_0000;
        let vtable = 0x120_0000;
        install_object(
            &mut mem,
            entry_addr,
            0x40,
            vtable,
            class_addr,
            &class_bytes,
            &[(0x10, &[1])],
        );

        assert!(is_visible_in_layout(
            &offsets,
            &class_bytes,
            entry_addr,
            &|a, l| mem.read(a, l)
        ));
    }

    #[test]
    fn is_visible_in_layout_false_when_flag_clear() {
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();

        let class_addr = 0x200_0000;
        let class_bytes = build_flat_class(
            &mut mem,
            0x201_0000,
            0x202_0000,
            0x203_0000,
            &[("IsVisibleInLayout", 0x10)],
        );
        let entry_addr = 0x210_0000;
        let vtable = 0x220_0000;
        install_object(
            &mut mem,
            entry_addr,
            0x40,
            vtable,
            class_addr,
            &class_bytes,
            &[(0x10, &[0])],
        );

        assert!(!is_visible_in_layout(
            &offsets,
            &class_bytes,
            entry_addr,
            &|a, l| mem.read(a, l)
        ));
    }

    #[test]
    fn is_visible_in_layout_defaults_true_when_field_missing() {
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();

        let class_addr = 0x400_0000;
        let class_bytes = build_flat_class(&mut mem, 0x401_0000, 0x402_0000, 0x403_0000, &[]);
        let entry_addr = 0x410_0000;
        let vtable = 0x420_0000;
        install_object(
            &mut mem,
            entry_addr,
            0x20,
            vtable,
            class_addr,
            &class_bytes,
            &[],
        );

        assert!(is_visible_in_layout(
            &offsets,
            &class_bytes,
            entry_addr,
            &|a, l| mem.read(a, l)
        ));
    }

    /// Install a full `CardLayoutData → Card → _model → _instance →
    /// BaseGrpId` chain, mirroring the production shape confirmed live
    /// via `walker_debug_class_fields("CardLayoutData")` on 2026-07-21:
    /// the class has `IsVisibleInLayout` but no `FaceDownState` field.
    /// Returns the holder's `_previousLayoutData` list address so the
    /// caller can install a holder pointing at it.
    fn install_layout_entry_chain(mem: &mut FakeMem, base: u64, arena_id: i32) -> u64 {
        // CardInstanceData: one field "BaseGrpId" at offset 0x10.
        let inst_class_addr = base + 0x100_0000;
        let inst_addr = base + 0x110_0000;
        let inst_vtable = base + 0x120_0000;
        let inst_class_bytes = build_flat_class(
            mem,
            base + 0x101_0000,
            base + 0x102_0000,
            base + 0x103_0000,
            &[("BaseGrpId", 0x10)],
        );
        let mut inst_payload = vec![0u8; 0x20];
        inst_payload[0..8].copy_from_slice(&inst_vtable.to_le_bytes());
        inst_payload[0x10..0x14].copy_from_slice(&arena_id.to_le_bytes());
        mem.add(inst_addr, inst_payload);
        let mut vt = vec![0u8; 0x50];
        vt[0..8].copy_from_slice(&inst_class_addr.to_le_bytes());
        mem.add(inst_vtable, vt);
        mem.add(inst_class_addr, inst_class_bytes);

        // CardDataAdapter: one field "_instance" at offset 0x18.
        let adapter_class_addr = base + 0x200_0000;
        let adapter_addr = base + 0x210_0000;
        let adapter_vtable = base + 0x220_0000;
        let adapter_class_bytes = build_flat_class(
            mem,
            base + 0x201_0000,
            base + 0x202_0000,
            base + 0x203_0000,
            &[("_instance", 0x18)],
        );
        install_object(
            mem,
            adapter_addr,
            0x40,
            adapter_vtable,
            adapter_class_addr,
            &adapter_class_bytes,
            &[(0x18, &inst_addr.to_le_bytes())],
        );

        // BASE_CDC: one field "_model" at offset 0x40.
        let base_cdc_class_addr = base + 0x300_0000;
        let base_cdc_class_bytes = build_flat_class(
            mem,
            base + 0x301_0000,
            base + 0x302_0000,
            base + 0x303_0000,
            &[("_model", 0x40)],
        );
        mem.add(base_cdc_class_addr, base_cdc_class_bytes);

        // DuelScene_CDC: parent → BASE_CDC, no own fields needed.
        let cdc_class_addr = base + 0x400_0000;
        let cdc_class_bytes = make_class_def_with_parent(0, 0, base_cdc_class_addr);
        let cdc_addr = base + 0x410_0000;
        let cdc_vtable = base + 0x420_0000;
        install_object(
            mem,
            cdc_addr,
            0x80,
            cdc_vtable,
            cdc_class_addr,
            &cdc_class_bytes,
            &[(0x40, &adapter_addr.to_le_bytes())],
        );

        // CardLayoutData (production shape): "IsVisibleInLayout" @
        // 0x48 and "Card" @ 0x10, NO "FaceDownState" field.
        let entry_class_addr = base + 0x500_0000;
        let entry_class_bytes = build_flat_class(
            mem,
            base + 0x501_0000,
            base + 0x502_0000,
            base + 0x503_0000,
            &[("Card", 0x10), ("IsVisibleInLayout", 0x48)],
        );
        let entry_addr = base + 0x510_0000;
        let entry_vtable = base + 0x520_0000;
        install_object(
            mem,
            entry_addr,
            0x50,
            entry_vtable,
            entry_class_addr,
            &entry_class_bytes,
            &[(0x10, &cdc_addr.to_le_bytes()), (0x48, &[1])],
        );

        // List<CardLayoutData> wrapping the single entry.
        let list_class_addr = base + 0x600_0000;
        let list_class_bytes = build_flat_class(
            mem,
            base + 0x601_0000,
            base + 0x602_0000,
            base + 0x603_0000,
            &[("_items", 0x10), ("_size", 0x18)],
        );
        mem.add(list_class_addr, list_class_bytes);
        let list_addr = base + 0x610_0000;
        let list_vtable = base + 0x620_0000;
        let items_ptr = base + 0x630_0000;
        let mut list_payload = vec![0u8; 0x30];
        list_payload[0..8].copy_from_slice(&list_vtable.to_le_bytes());
        list_payload[0x10..0x18].copy_from_slice(&items_ptr.to_le_bytes());
        list_payload[0x18..0x1c].copy_from_slice(&1i32.to_le_bytes());
        mem.add(list_addr, list_payload);
        let mut lvt = vec![0u8; 0x50];
        lvt[0..8].copy_from_slice(&list_class_addr.to_le_bytes());
        mem.add(list_vtable, lvt);
        mem.add(items_ptr + 0x20, entry_addr.to_le_bytes().to_vec());

        list_addr
    }

    /// Install a holder object whose `_previousLayoutData` points at
    /// `list_addr`.
    fn install_holder(mem: &mut FakeMem, base: u64, list_addr: u64) -> u64 {
        let holder_class_addr = base + 0x100_0000;
        let holder_class_bytes = build_flat_class(
            mem,
            base + 0x101_0000,
            base + 0x102_0000,
            base + 0x103_0000,
            &[("_previousLayoutData", 0x10)],
        );
        let holder_addr = base + 0x110_0000;
        let holder_vtable = base + 0x120_0000;
        install_object(
            mem,
            holder_addr,
            0x18,
            holder_vtable,
            holder_class_addr,
            &holder_class_bytes,
            &[(0x10, &list_addr.to_le_bytes())],
        );
        holder_addr
    }

    #[test]
    fn read_revealed_arena_ids_excludes_entry_with_unresolved_arena_id() {
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();

        // IsVisibleInLayout = true, but BaseGrpId = 0 — the shape MTGA
        // actually produces for an opponent's un-revealed hand card.
        let list_addr = install_layout_entry_chain(&mut mem, 0x5000_0000, 0);
        let holder_addr = install_holder(&mut mem, 0x6000_0000, list_addr);

        let result = read_revealed_arena_ids(&offsets, holder_addr, |a, l| mem.read(a, l));

        assert_eq!(
            result,
            Some(vec![]),
            "a card whose identity never resolved must not be reported as revealed"
        );
    }

    #[test]
    fn read_revealed_arena_ids_includes_entry_with_resolved_arena_id() {
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();

        let list_addr = install_layout_entry_chain(&mut mem, 0x7000_0000, 88_983);
        let holder_addr = install_holder(&mut mem, 0x8000_0000, list_addr);

        let result = read_revealed_arena_ids(&offsets, holder_addr, |a, l| mem.read(a, l));

        assert_eq!(result, Some(vec![88_983]));
    }
}
