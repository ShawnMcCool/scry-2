//! Drill `BaseCardHolder._previousLayoutData : List<CardLayoutData>`
//! to extract revealed-card arena_ids for non-battlefield zones (hand,
//! graveyard, exile).
//!
//! Each `CardLayoutData` has:
//!   - `Card : BaseCDC`            — the card display object
//!   - `IsVisibleInLayout : bool`  — true iff face-up in this layout
//!   - `FaceDownState`             — struct with `_reasonFaceDown` enum
//!
//! The "is revealed" filter is `IsVisibleInLayout == true &&
//! FaceDownState._reasonFaceDown == 0`. This naturally includes the
//! local player's full hand (always visible to themselves), only the
//! Thoughtseize/Duress-revealed entries in the opponent's hand, and
//! every face-up entry in graveyard / exile.

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

    let list_addr = read_pointer_at(holder_addr.checked_add(list_field.offset as u64)?, &read_mem)?;
    if list_addr == 0 {
        return Some(Vec::new());
    }

    let list_class_bytes = object::read_runtime_class_bytes(list_addr, &read_mem)?;
    let entry_pointers =
        list_t::read_pointer_list(offsets, &list_class_bytes, list_addr, &read_mem);

    let mut arena_ids = Vec::with_capacity(entry_pointers.len().min(limits::MAX_LIST_ELEMENTS));
    for entry_addr in entry_pointers
        .into_iter()
        .take(limits::MAX_LIST_ELEMENTS)
    {
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
/// it passes the revealed filter.
fn arena_id_for_layout_entry_if_revealed<F>(
    offsets: &MonoOffsets,
    entry_addr: u64,
    read_mem: &F,
) -> Option<i32>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let entry_class_bytes = object::read_runtime_class_bytes(entry_addr, read_mem)?;

    if !is_revealed(offsets, &entry_class_bytes, entry_addr, read_mem) {
        return None;
    }

    let card_field =
        field::find_field_by_name_in_chain(offsets, &entry_class_bytes, "Card", *read_mem)?;
    if card_field.is_static {
        return None;
    }
    let card_addr = read_pointer_at(entry_addr.checked_add(card_field.offset as u64)?, read_mem)?;

    card_holder::arena_id_for_cdc(offsets, card_addr, read_mem)
}

/// True when `IsVisibleInLayout` is set AND `FaceDownState._reasonFaceDown`
/// is zero (i.e. the card is genuinely visible — not morphed, cloaked,
/// or face-down).
///
/// Defensive default: when either field is unreadable, treat the entry
/// as revealed. We'd rather over-report than silently drop revealed
/// cards.
fn is_revealed<F>(
    offsets: &MonoOffsets,
    entry_class_bytes: &[u8],
    entry_addr: u64,
    read_mem: &F,
) -> bool
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let visible = match field::find_field_by_name_in_chain(
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
    };
    if !visible {
        return false;
    }

    let face_down_offset = match field::find_field_by_name_in_chain(
        offsets,
        entry_class_bytes,
        "FaceDownState",
        *read_mem,
    ) {
        Some(f) if !f.is_static => f.offset,
        _ => return true, // no FaceDownState field → assume revealed
    };

    let reason_addr = match entry_addr.checked_add(face_down_offset as u64) {
        Some(a) => a,
        None => return true,
    };

    // FaceDownState is an inlined value-type; its _reasonFaceDown enum
    // sits at the start of that struct as an i32. Read the first 4
    // bytes — non-zero means face-down for some reason.
    match read_mem(reason_addr, 4) {
        Some(bytes) if bytes.len() == 4 => {
            i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]) == 0
        }
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
    fn is_revealed_true_when_visible_and_no_face_down_reason() {
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();

        let class_addr = 0x100_0000;
        let class_bytes = build_flat_class(
            &mut mem,
            0x101_0000,
            0x102_0000,
            0x103_0000,
            &[("IsVisibleInLayout", 0x10), ("FaceDownState", 0x14)],
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
            &[(0x10, &[1]), (0x14, &0i32.to_le_bytes())],
        );

        assert!(is_revealed(&offsets, &class_bytes, entry_addr, &|a, l| mem.read(a, l)));
    }

    #[test]
    fn is_revealed_false_when_not_visible() {
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();

        let class_addr = 0x200_0000;
        let class_bytes = build_flat_class(
            &mut mem,
            0x201_0000,
            0x202_0000,
            0x203_0000,
            &[("IsVisibleInLayout", 0x10), ("FaceDownState", 0x14)],
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
            &[(0x10, &[0]), (0x14, &0i32.to_le_bytes())],
        );

        assert!(!is_revealed(&offsets, &class_bytes, entry_addr, &|a, l| mem.read(a, l)));
    }

    #[test]
    fn is_revealed_false_when_face_down_reason_set() {
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();

        let class_addr = 0x300_0000;
        let class_bytes = build_flat_class(
            &mut mem,
            0x301_0000,
            0x302_0000,
            0x303_0000,
            &[("IsVisibleInLayout", 0x10), ("FaceDownState", 0x14)],
        );
        let entry_addr = 0x310_0000;
        let vtable = 0x320_0000;
        install_object(
            &mut mem,
            entry_addr,
            0x40,
            vtable,
            class_addr,
            &class_bytes,
            &[(0x10, &[1]), (0x14, &7i32.to_le_bytes())],
        );

        assert!(!is_revealed(&offsets, &class_bytes, entry_addr, &|a, l| mem.read(a, l)));
    }

    #[test]
    fn is_revealed_defaults_visible_when_fields_missing() {
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

        assert!(is_revealed(&offsets, &class_bytes, entry_addr, &|a, l| mem.read(a, l)));
    }
}
