//! Drill into one MTGA `ICardHolder` to extract the arena_ids of
//! cards visible in that zone (Chain 2 final hop).
//!
//! ## Battlefield path (this module)
//!
//! ```text
//! BattlefieldCardHolder
//!   ._battlefieldLayout           (own field)
//!     -> BattlefieldLayout
//!         ._unattachedCardsCache  (own field, List<DuelScene_CDC>)
//!             -> per element: DuelScene_CDC *
//!                  -> BASE_CDC._model    (parent-class field)
//!                       -> CardDataAdapter
//!                            ._instance  (resolved by name)
//!                                 -> CardInstanceData.BaseGrpId : i32
//! ```
//!
//! Battlefield is the simpler of the two card-bearing chains MTGA
//! exposes — every card on the field appears as a direct
//! `DuelScene_CDC` reference in `_unattachedCardsCache`. There is no
//! `CardLayoutData` wrapper to unpack and no per-region/per-stack
//! drill (battlefield regions are layout metadata, not card storage).
//!
//! ## Per-card seat attribution
//!
//! `_unattachedCardsCache` is not split by player — `PlayerTypeMap`
//! (see `super::match_scene`) holds exactly one battlefield holder,
//! keyed `0`. So unlike Hand/Graveyard/Exile, the outer seat key is
//! useless here; each card's seat has to be read out of the card
//! itself: `CardDataAdapter._instance` (`MtgCardInstance`) `.Owner` →
//! `MtgPlayer.ClientPlayerEnum : i32` (same `1`=LocalPlayer,
//! `2`=Opponent encoding as the outer seat key elsewhere). Verified
//! live 2026-07-22 against 19 real battlefield cards in an active
//! match — see [`owner_seat_for_cdc`] and `plans.md` section D.
//!
//! ## Non-battlefield zones (Hand, Graveyard, Exile)
//!
//! Hand / Graveyard / Exile go through the universal
//! `CardHolderBase._previousLayoutData : List<CardLayoutData>` field,
//! handled by [`super::card_layout_data`]. The dispatcher
//! [`read_zone_arena_ids`] in this module routes by `zone_id`.
//! Stack and Command are not walked (see [`READABLE_ZONES`]).

use super::field;
use super::instance_field;
use super::limits;
use super::list_t;
use super::mono::{self, MonoOffsets, CLASS_DEF_BLOB_LEN};
use super::object;

/// MTGA zone enum value for the battlefield. Mirrored from the
/// `CardHolderType` enum documented in the `mono-memory-reader`
/// skill; the walker keeps these as integers (Elixir-side translation
/// owns the symbolic names).
pub const ZONE_BATTLEFIELD: i32 = 4;

/// Zone enum values that the walker reads. Hand (3), Battlefield (4),
/// Graveyard (5), Exile (6) — see `mono-memory-reader` skill for the
/// full CardHolderType enum.
///
/// Stack (9) and Command (10) are deliberately omitted: stack is
/// rarely populated at end-of-match and the player does not play
/// Brawl/Commander.
pub const READABLE_ZONES: &[i32] = &[3, 4, 5, 6];

/// Read every visible battlefield card as `(seat_id, arena_id)` pairs.
///
/// `seat_id` is resolved per card via [`owner_seat_for_cdc`] — the
/// outer `PlayerTypeMap` seat key is not usable for battlefield (see
/// that function's doc comment). Cards whose owner chain fails to
/// resolve get `seat_id = 0` (unknown) — the arena_id is still kept,
/// matching every other zone reader's partial-read tolerance.
///
/// Returns pairs in the order MTGA stored them in
/// `_unattachedCardsCache` (creation/play order). Empty `Vec` when
/// the chain is reachable but nothing is on the field; `None` only on
/// structural read failure (null pointers, unresolvable fields).
pub fn read_battlefield_cards<F>(
    offsets: &MonoOffsets,
    holder_addr: u64,
    read_mem: F,
) -> Option<Vec<(i32, i32)>>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let holder_class_bytes = object::read_runtime_class_bytes(holder_addr, &read_mem)?;

    // BattlefieldCardHolder._battlefieldLayout — own-class field.
    let layout_addr = object::read_instance_pointer(
        offsets,
        &holder_class_bytes,
        holder_addr,
        "_battlefieldLayout",
        &read_mem,
    )?;

    let layout_class_bytes = object::read_runtime_class_bytes(layout_addr, &read_mem)?;

    // BattlefieldLayout._unattachedCardsCache — own-class field.
    let list_addr = object::read_instance_pointer(
        offsets,
        &layout_class_bytes,
        layout_addr,
        "_unattachedCardsCache",
        &read_mem,
    )?;

    let list_class_bytes = object::read_runtime_class_bytes(list_addr, &read_mem)?;
    let cdc_pointers = list_t::read_pointer_list(offsets, &list_class_bytes, list_addr, &read_mem);

    let mut cards = Vec::with_capacity(cdc_pointers.len().min(limits::MAX_LIST_ELEMENTS));
    for cdc_ptr in cdc_pointers.into_iter().take(limits::MAX_LIST_ELEMENTS) {
        if let Some(arena_id) = arena_id_for_cdc(offsets, cdc_ptr, &read_mem) {
            let seat_id = owner_seat_for_cdc(offsets, cdc_ptr, &read_mem).unwrap_or(0);
            cards.push((seat_id, arena_id));
        }
        // Drop unresolvable entries — partial reads are better than no reads.
    }

    Some(cards)
}

/// Read every visible card's arena_id in a battlefield holder,
/// discarding per-card seat attribution.
///
/// Thin wrapper over [`read_battlefield_cards`] kept for callers that
/// only need the arena_ids (and for the existing test suite, which
/// predates per-card seat resolution).
pub fn read_battlefield_arena_ids<F>(
    offsets: &MonoOffsets,
    holder_addr: u64,
    read_mem: F,
) -> Option<Vec<i32>>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    read_battlefield_cards(offsets, holder_addr, read_mem).map(|cards| {
        cards
            .into_iter()
            .map(|(_seat_id, arena_id)| arena_id)
            .collect()
    })
}

/// Dispatch from a `(holder_addr, zone_id)` pair to the right reader.
///
/// - `ZONE_BATTLEFIELD` (4) → [`read_battlefield_arena_ids`]
/// - any other zone → [`super::card_layout_data::read_revealed_arena_ids`]
///
/// Returns the arena_ids in the order MTGA stored them in the holder's
/// underlying list. `None` only on structural read failure of the
/// dispatched path; `Some(vec![])` when reachable but empty.
pub fn read_zone_arena_ids<F>(
    offsets: &MonoOffsets,
    holder_addr: u64,
    zone_id: i32,
    read_mem: F,
) -> Option<Vec<i32>>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    if zone_id == ZONE_BATTLEFIELD {
        read_battlefield_arena_ids(offsets, holder_addr, read_mem)
    } else {
        super::card_layout_data::read_revealed_arena_ids(offsets, holder_addr, read_mem)
    }
}

/// Drill one `BaseCDC` (or any `*_CDC` subclass) to its
/// `MtgCardInstance` object address: `BASE_CDC._model` (parent-class
/// field) → `CardDataAdapter._instance`.
///
/// Shared prefix of [`arena_id_for_cdc`] and [`owner_seat_for_cdc`] —
/// both need the same card-instance object, just different fields off
/// it.
///
/// `_model` lives on `BASE_CDC`, not on the concrete subclass, so we
/// need [`field::find_field_by_name_in_chain`] for the first hop.
/// `_instance` lives on its own class (verified by follow-up spike
/// data) and uses the flat resolver.
fn card_instance_addr_for_cdc<F>(offsets: &MonoOffsets, cdc_addr: u64, read_mem: &F) -> Option<u64>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    if cdc_addr == 0 {
        return None;
    }

    let cdc_class_bytes = object::read_runtime_class_bytes(cdc_addr, read_mem)?;

    // BASE_CDC._model — parent-class field.
    let model_field =
        field::find_field_by_name_in_chain(offsets, &cdc_class_bytes, "_model", *read_mem)?;
    if model_field.is_static {
        return None;
    }
    let model_addr = read_pointer_at(cdc_addr.checked_add(model_field.offset as u64)?, read_mem)?;
    if model_addr == 0 {
        return None;
    }

    let model_class_bytes = object::read_runtime_class_bytes(model_addr, read_mem)?;

    // CardDataAdapter._instance — resolve by name (parent-aware in case
    // it lives on a base class in this build).
    let instance_field =
        field::find_field_by_name_in_chain(offsets, &model_class_bytes, "_instance", *read_mem)?;
    if instance_field.is_static {
        return None;
    }
    let instance_addr = read_pointer_at(
        model_addr.checked_add(instance_field.offset as u64)?,
        read_mem,
    )?;
    if instance_addr == 0 {
        None
    } else {
        Some(instance_addr)
    }
}

/// Drill one `BaseCDC` (or any `*_CDC` subclass) to its arena_id:
/// [`card_instance_addr_for_cdc`] → `CardInstanceData.BaseGrpId : i32`.
pub fn arena_id_for_cdc<F>(offsets: &MonoOffsets, cdc_addr: u64, read_mem: &F) -> Option<i32>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let instance_addr = card_instance_addr_for_cdc(offsets, cdc_addr, read_mem)?;
    let instance_class_bytes = object::read_runtime_class_bytes(instance_addr, read_mem)?;

    // CardInstanceData.BaseGrpId — i32 by name (parent-aware).
    instance_field::read_instance_i32_in_chain(
        offsets,
        &instance_class_bytes,
        instance_addr,
        "BaseGrpId",
        read_mem,
    )
}

/// Drill one `BaseCDC` to the client-relative seat id of the card's
/// owner: [`card_instance_addr_for_cdc`] →
/// `MtgCardInstance.Owner` → `MtgPlayer.ClientPlayerEnum : i32`.
///
/// `ClientPlayerEnum` uses the same `GREPlayerNum` encoding
/// (`LocalPlayer=1, Opponent=2`) as the outer `PlayerTypeMap` seat key
/// `match_scene.rs` reads for every other zone. Needed specifically
/// for battlefield: verified live 2026-07-22 that MTGA's
/// `PlayerTypeMap` holds exactly one battlefield holder, keyed `0` —
/// there's no per-seat holder to key off of for this zone the way
/// there is for Hand/Graveyard/Exile, so per-card seat has to be read
/// out of the card itself. `MtgCardInstance.Controller` (same offset
/// pattern) resolves to the same object in every case observed and
/// was not used — `Owner` was chosen since it's the semantically
/// stable one across control-changing effects.
pub fn owner_seat_for_cdc<F>(offsets: &MonoOffsets, cdc_addr: u64, read_mem: &F) -> Option<i32>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let instance_addr = card_instance_addr_for_cdc(offsets, cdc_addr, read_mem)?;
    let instance_class_bytes = object::read_runtime_class_bytes(instance_addr, read_mem)?;

    let owner_addr = object::read_instance_pointer_in_chain(
        offsets,
        &instance_class_bytes,
        instance_addr,
        "Owner",
        read_mem,
    )?;

    let owner_class_bytes = object::read_runtime_class_bytes(owner_addr, read_mem)?;
    instance_field::read_instance_i32_in_chain(
        offsets,
        &owner_class_bytes,
        owner_addr,
        "ClientPlayerEnum",
        read_mem,
    )
}

/// Read a pointer-sized value at `addr`. Helper that mirrors the
/// inline pattern other walker modules use, kept local to avoid a
/// public surface for it.
fn read_pointer_at<F>(addr: u64, read_mem: &F) -> Option<u64>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let bytes = read_mem(addr, 8)?;
    mono::read_u64(&bytes, 0, 0)
}

// Suppress unused-import lint if MAX_LIST_ELEMENTS path drift; the
// import is used in the take(...) above.
#[allow(unused_imports)]
use super::limits as _limits_keepalive;

// CLASS_DEF_BLOB_LEN re-exported for downstream test use; the
// production paths above all go through helpers that already cap reads.
#[allow(dead_code)]
const _CLASS_DEF_BLOB_LEN: usize = CLASS_DEF_BLOB_LEN;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::walker::mono::MONO_CLASS_FIELD_SIZE;
    use crate::walker::test_support::{
        make_class_def, make_class_def_with_parent, make_field_entry, make_type_block, FakeMem,
    };

    /// Install an object whose `vtable.klass` points at `class_addr`.
    fn install_object(
        mem: &mut FakeMem,
        obj_addr: u64,
        payload_size: usize,
        vtable_addr: u64,
        class_addr: u64,
        class_bytes: &[u8],
        stamps: &[(i32, u64)],
    ) {
        let mut payload = vec![0u8; payload_size.max(0x10)];
        payload[0..8].copy_from_slice(&vtable_addr.to_le_bytes());
        for (off, ptr) in stamps {
            let off = *off as usize;
            payload[off..off + 8].copy_from_slice(&ptr.to_le_bytes());
        }
        mem.add(obj_addr, payload);
        let mut vt = vec![0u8; 0x50];
        vt[0..8].copy_from_slice(&class_addr.to_le_bytes());
        mem.add(vtable_addr, vt);
        mem.add(class_addr, class_bytes.to_vec());
    }

    /// Build a class with one named field at the given offset; install
    /// the field-array bytes into `mem`.
    fn build_class_with_one_field(
        mem: &mut FakeMem,
        fields_base: u64,
        names_base: u64,
        types_base: u64,
        parent_ptr: u64,
        field_name: &str,
        field_offset: i32,
    ) -> Vec<u8> {
        let entry = make_field_entry(names_base, types_base, 0, field_offset);
        mem.add(fields_base, entry);
        let mut name_buf = field_name.as_bytes().to_vec();
        name_buf.push(0);
        mem.add(names_base, name_buf);
        mem.add(types_base, make_type_block(0));
        if parent_ptr == 0 {
            make_class_def(fields_base, 1)
        } else {
            make_class_def_with_parent(fields_base, 1, parent_ptr)
        }
    }

    /// Build a class with multiple named fields. `fields` is
    /// `[(name, offset)]`. All fields are non-static.
    fn build_class_with_fields(
        mem: &mut FakeMem,
        fields_base: u64,
        names_base: u64,
        types_base: u64,
        parent_ptr: u64,
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
        if parent_ptr == 0 {
            make_class_def(fields_base, fields.len() as u32)
        } else {
            make_class_def_with_parent(fields_base, fields.len() as u32, parent_ptr)
        }
    }

    /// Install a `MonoArray<u64>` at `array_addr` whose vector storage
    /// holds the given pointers at `array_addr + 0x20`.
    fn install_pointer_array(mem: &mut FakeMem, array_addr: u64, ptrs: &[u64]) {
        let offsets = MonoOffsets::mtga_default();
        let mut header = vec![0u8; offsets.array_vector];
        header[offsets.array_max_length..offsets.array_max_length + 8]
            .copy_from_slice(&(ptrs.len() as u64).to_le_bytes());
        mem.add(array_addr, header);
        let mut vec_bytes = Vec::with_capacity(ptrs.len() * 8);
        for p in ptrs {
            vec_bytes.extend_from_slice(&p.to_le_bytes());
        }
        mem.add(array_addr + offsets.array_vector as u64, vec_bytes);
    }

    /// End-to-end fixture: install a fake CDC at `cdc_addr` pointing
    /// at a fake CardDataAdapter that points at a fake
    /// CardInstanceData with `BaseGrpId = arena_id`.
    fn install_full_card_chain(mem: &mut FakeMem, base: u64, cdc_addr: u64, arena_id: i32) -> u64 {
        // CardInstanceData class: one field "BaseGrpId" at offset 0x10.
        let inst_class_addr = base + 0x100_0000;
        let inst_addr = base + 0x110_0000;
        let inst_vtable = base + 0x120_0000;
        let inst_class_bytes = build_class_with_one_field(
            mem,
            base + 0x101_0000,
            base + 0x102_0000,
            base + 0x103_0000,
            0,
            "BaseGrpId",
            0x10,
        );
        let mut inst_payload = vec![0u8; 0x20];
        inst_payload[0..8].copy_from_slice(&inst_vtable.to_le_bytes());
        inst_payload[0x10..0x14].copy_from_slice(&arena_id.to_le_bytes());
        mem.add(inst_addr, inst_payload);
        let mut vt = vec![0u8; 0x50];
        vt[0..8].copy_from_slice(&inst_class_addr.to_le_bytes());
        mem.add(inst_vtable, vt);
        mem.add(inst_class_addr, inst_class_bytes);

        // CardDataAdapter class: one field "_instance" at offset 0x18.
        let adapter_class_addr = base + 0x200_0000;
        let adapter_addr = base + 0x210_0000;
        let adapter_vtable = base + 0x220_0000;
        let adapter_class_bytes = build_class_with_one_field(
            mem,
            base + 0x201_0000,
            base + 0x202_0000,
            base + 0x203_0000,
            0,
            "_instance",
            0x18,
        );
        install_object(
            mem,
            adapter_addr,
            0x40,
            adapter_vtable,
            adapter_class_addr,
            &adapter_class_bytes,
            &[(0x18, inst_addr)],
        );

        // BASE_CDC parent class with "_model" at offset 0x40.
        let base_cdc_class_addr = base + 0x300_0000;
        let base_cdc_class_bytes = build_class_with_one_field(
            mem,
            base + 0x301_0000,
            base + 0x302_0000,
            base + 0x303_0000,
            0,
            "_model",
            0x40,
        );
        mem.add(base_cdc_class_addr, base_cdc_class_bytes);

        // DuelScene_CDC subclass with parent → BASE_CDC; declares an
        // unrelated own-field at offset 0x100 to prove parent-walking
        // is required.
        let cdc_class_addr = base + 0x400_0000;
        let cdc_class_bytes = build_class_with_one_field(
            mem,
            base + 0x401_0000,
            base + 0x402_0000,
            base + 0x403_0000,
            base_cdc_class_addr,
            "_unrelated_own_field",
            0x100,
        );
        let cdc_vtable = base + 0x420_0000;
        install_object(
            mem,
            cdc_addr,
            0x80,
            cdc_vtable,
            cdc_class_addr,
            &cdc_class_bytes,
            &[(0x40, adapter_addr)],
        );

        cdc_addr
    }

    /// Like [`install_full_card_chain`] but also wires
    /// `CardInstanceData.Owner` to a fake `MtgPlayer` whose
    /// `ClientPlayerEnum` field holds `seat_id` — the chain
    /// [`owner_seat_for_cdc`] drills.
    fn install_full_card_chain_with_owner(
        mem: &mut FakeMem,
        base: u64,
        cdc_addr: u64,
        arena_id: i32,
        seat_id: i32,
    ) -> u64 {
        // MtgPlayer class: one field "ClientPlayerEnum" at offset 0x30.
        let player_class_addr = base + 0x500_0000;
        let player_addr = base + 0x510_0000;
        let player_vtable = base + 0x520_0000;
        let player_class_bytes = build_class_with_one_field(
            mem,
            base + 0x501_0000,
            base + 0x502_0000,
            base + 0x503_0000,
            0,
            "ClientPlayerEnum",
            0x30,
        );
        let mut player_payload = vec![0u8; 0x40];
        player_payload[0..8].copy_from_slice(&player_vtable.to_le_bytes());
        player_payload[0x30..0x34].copy_from_slice(&seat_id.to_le_bytes());
        mem.add(player_addr, player_payload);
        let mut player_vt = vec![0u8; 0x50];
        player_vt[0..8].copy_from_slice(&player_class_addr.to_le_bytes());
        mem.add(player_vtable, player_vt);
        mem.add(player_class_addr, player_class_bytes);

        // CardInstanceData class: "BaseGrpId" @ 0x10, "Owner" @ 0x20.
        let inst_class_addr = base + 0x100_0000;
        let inst_addr = base + 0x110_0000;
        let inst_vtable = base + 0x120_0000;
        let inst_class_bytes = build_class_with_fields(
            mem,
            base + 0x101_0000,
            base + 0x102_0000,
            base + 0x103_0000,
            0,
            &[("BaseGrpId", 0x10), ("Owner", 0x20)],
        );
        let mut inst_payload = vec![0u8; 0x30];
        inst_payload[0..8].copy_from_slice(&inst_vtable.to_le_bytes());
        inst_payload[0x10..0x14].copy_from_slice(&arena_id.to_le_bytes());
        inst_payload[0x20..0x28].copy_from_slice(&player_addr.to_le_bytes());
        mem.add(inst_addr, inst_payload);
        let mut inst_vt = vec![0u8; 0x50];
        inst_vt[0..8].copy_from_slice(&inst_class_addr.to_le_bytes());
        mem.add(inst_vtable, inst_vt);
        mem.add(inst_class_addr, inst_class_bytes);

        // CardDataAdapter class: one field "_instance" at offset 0x18.
        let adapter_class_addr = base + 0x200_0000;
        let adapter_addr = base + 0x210_0000;
        let adapter_vtable = base + 0x220_0000;
        let adapter_class_bytes = build_class_with_one_field(
            mem,
            base + 0x201_0000,
            base + 0x202_0000,
            base + 0x203_0000,
            0,
            "_instance",
            0x18,
        );
        install_object(
            mem,
            adapter_addr,
            0x40,
            adapter_vtable,
            adapter_class_addr,
            &adapter_class_bytes,
            &[(0x18, inst_addr)],
        );

        // BASE_CDC parent class with "_model" at offset 0x40.
        let base_cdc_class_addr = base + 0x300_0000;
        let base_cdc_class_bytes = build_class_with_one_field(
            mem,
            base + 0x301_0000,
            base + 0x302_0000,
            base + 0x303_0000,
            0,
            "_model",
            0x40,
        );
        mem.add(base_cdc_class_addr, base_cdc_class_bytes);

        // DuelScene_CDC subclass with parent → BASE_CDC.
        let cdc_class_addr = base + 0x400_0000;
        let cdc_class_bytes = build_class_with_one_field(
            mem,
            base + 0x401_0000,
            base + 0x402_0000,
            base + 0x403_0000,
            base_cdc_class_addr,
            "_unrelated_own_field",
            0x100,
        );
        let cdc_vtable = base + 0x420_0000;
        install_object(
            mem,
            cdc_addr,
            0x80,
            cdc_vtable,
            cdc_class_addr,
            &cdc_class_bytes,
            &[(0x40, adapter_addr)],
        );

        cdc_addr
    }

    #[test]
    fn owner_seat_for_cdc_resolves_client_player_enum() -> Result<(), String> {
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();
        let cdc_addr = 0x1500_0000;
        install_full_card_chain_with_owner(&mut mem, 0x1600_0000, cdc_addr, 55_555, 2);

        let result = owner_seat_for_cdc(&offsets, cdc_addr, &|a, l| mem.read(a, l));
        assert_eq!(result, Some(2));
        Ok(())
    }

    #[test]
    fn owner_seat_for_cdc_returns_none_when_owner_field_missing() {
        // install_full_card_chain's CardInstanceData has no "Owner"
        // field at all — chain stops cleanly, doesn't panic.
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();
        let cdc_addr = 0x1700_0000;
        install_full_card_chain(&mut mem, 0x1800_0000, cdc_addr, 1);

        let result = owner_seat_for_cdc(&offsets, cdc_addr, &|a, l| mem.read(a, l));
        assert_eq!(result, None);
    }

    #[test]
    fn read_battlefield_cards_returns_arena_id_and_seat_pairs() -> Result<(), String> {
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();

        let cdc_a = 0x1900_0000;
        let cdc_b = 0x1a00_0000;
        install_full_card_chain_with_owner(&mut mem, 0x1900_4000_0000, cdc_a, 100, 1);
        install_full_card_chain_with_owner(&mut mem, 0x1a00_4000_0000, cdc_b, 200, 2);

        let list_array_addr: u64 = 0x1b00_0000;
        install_pointer_array(&mut mem, list_array_addr, &[cdc_a, cdc_b]);

        let list_addr: u64 = 0x1b10_0000;
        let list_vtable: u64 = 0x1b20_0000;
        let list_class_addr: u64 = 0x1b30_0000;
        let list_class_bytes = build_class_with_fields(
            &mut mem,
            0x1b40_0000,
            0x1b50_0000,
            0x1b60_0000,
            0,
            &[("_items", 0x10), ("_size", 0x18)],
        );
        let mut list_payload = vec![0u8; 0x40];
        list_payload[0..8].copy_from_slice(&list_vtable.to_le_bytes());
        list_payload[0x10..0x18].copy_from_slice(&list_array_addr.to_le_bytes());
        list_payload[0x18..0x1c].copy_from_slice(&2i32.to_le_bytes());
        mem.add(list_addr, list_payload);
        let mut vt = vec![0u8; 0x50];
        vt[0..8].copy_from_slice(&list_class_addr.to_le_bytes());
        mem.add(list_vtable, vt);
        mem.add(list_class_addr, list_class_bytes);

        let layout_addr: u64 = 0x1c00_0000;
        let layout_vtable: u64 = 0x1c10_0000;
        let layout_class_addr: u64 = 0x1c20_0000;
        let layout_class_bytes = build_class_with_one_field(
            &mut mem,
            0x1c30_0000,
            0x1c40_0000,
            0x1c50_0000,
            0,
            "_unattachedCardsCache",
            0x20,
        );
        install_object(
            &mut mem,
            layout_addr,
            0x40,
            layout_vtable,
            layout_class_addr,
            &layout_class_bytes,
            &[(0x20, list_addr)],
        );

        let holder_addr: u64 = 0x1d00_0000;
        let holder_vtable: u64 = 0x1d10_0000;
        let holder_class_addr: u64 = 0x1d20_0000;
        let holder_class_bytes = build_class_with_one_field(
            &mut mem,
            0x1d30_0000,
            0x1d40_0000,
            0x1d50_0000,
            0,
            "_battlefieldLayout",
            0x30,
        );
        install_object(
            &mut mem,
            holder_addr,
            0x40,
            holder_vtable,
            holder_class_addr,
            &holder_class_bytes,
            &[(0x30, layout_addr)],
        );

        let cards = read_battlefield_cards(&offsets, holder_addr, |a, l| mem.read(a, l))
            .ok_or("should return Some")?;

        assert_eq!(cards, vec![(1, 100), (2, 200)]);
        Ok(())
    }

    #[test]
    fn arena_id_for_cdc_walks_full_chain() -> Result<(), String> {
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();
        let cdc_addr = 0x500_0000;
        install_full_card_chain(&mut mem, 0x600_0000, cdc_addr, 67_001);

        let result = arena_id_for_cdc(&offsets, cdc_addr, &|a, l| mem.read(a, l));
        assert_eq!(result, Some(67_001));
        Ok(())
    }

    #[test]
    fn arena_id_for_cdc_returns_none_for_null_addr() {
        let mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();
        let result = arena_id_for_cdc(&offsets, 0, &|a, l| mem.read(a, l));
        assert_eq!(result, None);
    }

    #[test]
    fn arena_id_for_cdc_returns_none_when_model_pointer_null() {
        // CDC whose _model slot is 0 — chain stops cleanly.
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();
        let cdc_addr = 0x700_0000;

        let base_cdc_class_addr = 0x700_2000;
        let base_cdc_class_bytes = build_class_with_one_field(
            &mut mem, 0x700_3000, 0x700_4000, 0x700_5000, 0, "_model", 0x40,
        );
        mem.add(base_cdc_class_addr, base_cdc_class_bytes);

        let cdc_class_addr = 0x700_6000;
        let cdc_class_bytes = build_class_with_one_field(
            &mut mem,
            0x700_7000,
            0x700_8000,
            0x700_9000,
            base_cdc_class_addr,
            "_other",
            0x100,
        );
        let cdc_vtable = 0x700_a000;
        install_object(
            &mut mem,
            cdc_addr,
            0x80,
            cdc_vtable,
            cdc_class_addr,
            &cdc_class_bytes,
            &[/* _model slot left zero */],
        );

        let result = arena_id_for_cdc(&offsets, cdc_addr, &|a, l| mem.read(a, l));
        assert_eq!(result, None);
    }

    #[test]
    fn read_battlefield_arena_ids_returns_all_card_ids() -> Result<(), String> {
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();

        // Three CDCs, three different arena_ids.
        let cdc_a = 0x800_0000;
        let cdc_b = 0x900_0000;
        let cdc_c = 0xa00_0000;
        install_full_card_chain(&mut mem, 0x800_4000_0000, cdc_a, 100);
        install_full_card_chain(&mut mem, 0x900_4000_0000, cdc_b, 200);
        install_full_card_chain(&mut mem, 0xa00_4000_0000, cdc_c, 300);

        // List<DuelScene_CDC> with the three pointers.
        let list_array_addr: u64 = 0xb00_0000;
        install_pointer_array(&mut mem, list_array_addr, &[cdc_a, cdc_b, cdc_c]);

        // List class declares "_items" @ 0x10 and "_size" @ 0x18.
        let list_addr: u64 = 0xb10_0000;
        let list_vtable: u64 = 0xb20_0000;
        let list_class_addr: u64 = 0xb30_0000;
        let list_class_bytes = build_class_with_fields(
            &mut mem,
            0xb40_0000,
            0xb50_0000,
            0xb60_0000,
            0,
            &[("_items", 0x10), ("_size", 0x18)],
        );
        let mut list_payload = vec![0u8; 0x40];
        list_payload[0..8].copy_from_slice(&list_vtable.to_le_bytes());
        list_payload[0x10..0x18].copy_from_slice(&list_array_addr.to_le_bytes());
        list_payload[0x18..0x1c].copy_from_slice(&3i32.to_le_bytes());
        mem.add(list_addr, list_payload);
        let mut vt = vec![0u8; 0x50];
        vt[0..8].copy_from_slice(&list_class_addr.to_le_bytes());
        mem.add(list_vtable, vt);
        mem.add(list_class_addr, list_class_bytes);

        // BattlefieldLayout class declares "_unattachedCardsCache" @ 0x20.
        let layout_addr: u64 = 0xc00_0000;
        let layout_vtable: u64 = 0xc10_0000;
        let layout_class_addr: u64 = 0xc20_0000;
        let layout_class_bytes = build_class_with_one_field(
            &mut mem,
            0xc30_0000,
            0xc40_0000,
            0xc50_0000,
            0,
            "_unattachedCardsCache",
            0x20,
        );
        install_object(
            &mut mem,
            layout_addr,
            0x40,
            layout_vtable,
            layout_class_addr,
            &layout_class_bytes,
            &[(0x20, list_addr)],
        );

        // BattlefieldCardHolder declares "_battlefieldLayout" @ 0x30.
        let holder_addr: u64 = 0xd00_0000;
        let holder_vtable: u64 = 0xd10_0000;
        let holder_class_addr: u64 = 0xd20_0000;
        let holder_class_bytes = build_class_with_one_field(
            &mut mem,
            0xd30_0000,
            0xd40_0000,
            0xd50_0000,
            0,
            "_battlefieldLayout",
            0x30,
        );
        install_object(
            &mut mem,
            holder_addr,
            0x40,
            holder_vtable,
            holder_class_addr,
            &holder_class_bytes,
            &[(0x30, layout_addr)],
        );

        let arena_ids = read_battlefield_arena_ids(&offsets, holder_addr, |a, l| mem.read(a, l))
            .ok_or("should return Some")?;

        assert_eq!(arena_ids, vec![100, 200, 300]);
        Ok(())
    }

    #[test]
    fn read_battlefield_arena_ids_returns_empty_for_empty_list() -> Result<(), String> {
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();

        // List with size=0.
        let list_array_addr: u64 = 0x1_b00_0000;
        install_pointer_array(&mut mem, list_array_addr, &[]);

        let list_addr: u64 = 0x1_b10_0000;
        let list_vtable: u64 = 0x1_b20_0000;
        let list_class_addr: u64 = 0x1_b30_0000;
        let list_class_bytes = build_class_with_fields(
            &mut mem,
            0x1_b40_0000,
            0x1_b50_0000,
            0x1_b60_0000,
            0,
            &[("_items", 0x10), ("_size", 0x18)],
        );
        let mut list_payload = vec![0u8; 0x40];
        list_payload[0..8].copy_from_slice(&list_vtable.to_le_bytes());
        list_payload[0x10..0x18].copy_from_slice(&list_array_addr.to_le_bytes());
        // _size left at 0
        mem.add(list_addr, list_payload);
        let mut vt = vec![0u8; 0x50];
        vt[0..8].copy_from_slice(&list_class_addr.to_le_bytes());
        mem.add(list_vtable, vt);
        mem.add(list_class_addr, list_class_bytes);

        let layout_addr: u64 = 0x1_c00_0000;
        let layout_vtable: u64 = 0x1_c10_0000;
        let layout_class_addr: u64 = 0x1_c20_0000;
        let layout_class_bytes = build_class_with_one_field(
            &mut mem,
            0x1_c30_0000,
            0x1_c40_0000,
            0x1_c50_0000,
            0,
            "_unattachedCardsCache",
            0x20,
        );
        install_object(
            &mut mem,
            layout_addr,
            0x40,
            layout_vtable,
            layout_class_addr,
            &layout_class_bytes,
            &[(0x20, list_addr)],
        );

        let holder_addr: u64 = 0x1_d00_0000;
        let holder_vtable: u64 = 0x1_d10_0000;
        let holder_class_addr: u64 = 0x1_d20_0000;
        let holder_class_bytes = build_class_with_one_field(
            &mut mem,
            0x1_d30_0000,
            0x1_d40_0000,
            0x1_d50_0000,
            0,
            "_battlefieldLayout",
            0x30,
        );
        install_object(
            &mut mem,
            holder_addr,
            0x40,
            holder_vtable,
            holder_class_addr,
            &holder_class_bytes,
            &[(0x30, layout_addr)],
        );

        let arena_ids = read_battlefield_arena_ids(&offsets, holder_addr, |a, l| mem.read(a, l))
            .ok_or("should return Some")?;
        assert!(arena_ids.is_empty());
        Ok(())
    }

    #[test]
    fn read_zone_arena_ids_routes_battlefield_through_battlefield_path() -> Result<(), String> {
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();

        let cdc = 0x500_0000;
        install_full_card_chain(&mut mem, 0x600_0000, cdc, 7777);

        let list_array_addr: u64 = 0xb00_0000;
        install_pointer_array(&mut mem, list_array_addr, &[cdc]);

        let list_addr: u64 = 0xb10_0000;
        let list_vtable: u64 = 0xb20_0000;
        let list_class_addr: u64 = 0xb30_0000;
        let list_class_bytes = build_class_with_fields(
            &mut mem,
            0xb40_0000,
            0xb50_0000,
            0xb60_0000,
            0,
            &[("_items", 0x10), ("_size", 0x18)],
        );
        let mut list_payload = vec![0u8; 0x40];
        list_payload[0..8].copy_from_slice(&list_vtable.to_le_bytes());
        list_payload[0x10..0x18].copy_from_slice(&list_array_addr.to_le_bytes());
        list_payload[0x18..0x1c].copy_from_slice(&1i32.to_le_bytes());
        mem.add(list_addr, list_payload);
        let mut vt = vec![0u8; 0x50];
        vt[0..8].copy_from_slice(&list_class_addr.to_le_bytes());
        mem.add(list_vtable, vt);
        mem.add(list_class_addr, list_class_bytes);

        let layout_addr: u64 = 0xc00_0000;
        let layout_vtable: u64 = 0xc10_0000;
        let layout_class_addr: u64 = 0xc20_0000;
        let layout_class_bytes = build_class_with_one_field(
            &mut mem,
            0xc30_0000,
            0xc40_0000,
            0xc50_0000,
            0,
            "_unattachedCardsCache",
            0x20,
        );
        install_object(
            &mut mem,
            layout_addr,
            0x40,
            layout_vtable,
            layout_class_addr,
            &layout_class_bytes,
            &[(0x20, list_addr)],
        );

        let holder_addr: u64 = 0xd00_0000;
        let holder_vtable: u64 = 0xd10_0000;
        let holder_class_addr: u64 = 0xd20_0000;
        let holder_class_bytes = build_class_with_one_field(
            &mut mem,
            0xd30_0000,
            0xd40_0000,
            0xd50_0000,
            0,
            "_battlefieldLayout",
            0x30,
        );
        install_object(
            &mut mem,
            holder_addr,
            0x40,
            holder_vtable,
            holder_class_addr,
            &holder_class_bytes,
            &[(0x30, layout_addr)],
        );

        let arena_ids = read_zone_arena_ids(&offsets, holder_addr, ZONE_BATTLEFIELD, |a, l| {
            mem.read(a, l)
        })
        .ok_or("expected Some")?;
        assert_eq!(arena_ids, vec![7777]);
        Ok(())
    }

    #[test]
    fn read_zone_arena_ids_routes_non_battlefield_through_layout_data_path() -> Result<(), String> {
        // Holder with no _battlefieldLayout, but with a
        // _previousLayoutData containing one revealed CardLayoutData
        // wrapping a CDC for arena_id 4242.
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();

        let cdc: u64 = 0x2_500_0000;
        install_full_card_chain(&mut mem, 0x2_600_0000, cdc, 4242);

        // CardLayoutData class: Card@0x10, IsVisibleInLayout@0x18,
        // FaceDownState@0x1c.
        // NOTE: install_full_card_chain(base=0x2_600_0000) occupies up to
        // base+0x420_0000 = 0x2_A20_0000, so start fixtures at 0x3_000_0000.
        let cld_class_addr: u64 = 0x3_000_0000;
        let cld_class_bytes = build_class_with_fields(
            &mut mem,
            0x3_010_0000,
            0x3_020_0000,
            0x3_030_0000,
            0,
            &[
                ("Card", 0x10),
                ("IsVisibleInLayout", 0x18),
                ("FaceDownState", 0x1c),
            ],
        );
        let cld_addr: u64 = 0x3_040_0000;
        let cld_vtable: u64 = 0x3_050_0000;
        let mut cld_payload = vec![0u8; 0x40];
        cld_payload[0..8].copy_from_slice(&cld_vtable.to_le_bytes());
        cld_payload[0x10..0x18].copy_from_slice(&cdc.to_le_bytes());
        cld_payload[0x18] = 1;
        cld_payload[0x1c..0x20].copy_from_slice(&0i32.to_le_bytes());
        mem.add(cld_addr, cld_payload);
        let mut vt = vec![0u8; 0x50];
        vt[0..8].copy_from_slice(&cld_class_addr.to_le_bytes());
        mem.add(cld_vtable, vt);
        mem.add(cld_class_addr, cld_class_bytes);

        // List<CardLayoutData> wrapping the one entry.
        let list_array_addr: u64 = 0x3_100_0000;
        install_pointer_array(&mut mem, list_array_addr, &[cld_addr]);

        let list_addr: u64 = 0x3_110_0000;
        let list_vtable: u64 = 0x3_120_0000;
        let list_class_addr: u64 = 0x3_130_0000;
        let list_class_bytes = build_class_with_fields(
            &mut mem,
            0x3_140_0000,
            0x3_150_0000,
            0x3_160_0000,
            0,
            &[("_items", 0x10), ("_size", 0x18)],
        );
        let mut list_payload = vec![0u8; 0x40];
        list_payload[0..8].copy_from_slice(&list_vtable.to_le_bytes());
        list_payload[0x10..0x18].copy_from_slice(&list_array_addr.to_le_bytes());
        list_payload[0x18..0x1c].copy_from_slice(&1i32.to_le_bytes());
        mem.add(list_addr, list_payload);
        let mut vt2 = vec![0u8; 0x50];
        vt2[0..8].copy_from_slice(&list_class_addr.to_le_bytes());
        mem.add(list_vtable, vt2);
        mem.add(list_class_addr, list_class_bytes);

        // Holder with _previousLayoutData @ 0xa8.
        let holder_addr: u64 = 0x3_200_0000;
        let holder_vtable: u64 = 0x3_210_0000;
        let holder_class_addr: u64 = 0x3_220_0000;
        let holder_class_bytes = build_class_with_one_field(
            &mut mem,
            0x3_230_0000,
            0x3_240_0000,
            0x3_250_0000,
            0,
            "_previousLayoutData",
            0xa8,
        );
        let mut payload = vec![0u8; 0xc0];
        payload[0..8].copy_from_slice(&holder_vtable.to_le_bytes());
        payload[0xa8..0xb0].copy_from_slice(&list_addr.to_le_bytes());
        mem.add(holder_addr, payload);
        let mut vt3 = vec![0u8; 0x50];
        vt3[0..8].copy_from_slice(&holder_class_addr.to_le_bytes());
        mem.add(holder_vtable, vt3);
        mem.add(holder_class_addr, holder_class_bytes);

        // Zone 5 (graveyard) — anything non-battlefield routes the same.
        let arena_ids = read_zone_arena_ids(&offsets, holder_addr, 5, |a, l| mem.read(a, l))
            .ok_or("expected Some")?;
        assert_eq!(arena_ids, vec![4242]);
        Ok(())
    }

    #[test]
    fn read_battlefield_arena_ids_returns_none_when_layout_missing() {
        // Holder class without _battlefieldLayout field — chain stops.
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();

        let holder_addr: u64 = 0x2_d00_0000;
        let holder_vtable: u64 = 0x2_d10_0000;
        let holder_class_addr: u64 = 0x2_d20_0000;
        let holder_class_bytes = build_class_with_one_field(
            &mut mem,
            0x2_d30_0000,
            0x2_d40_0000,
            0x2_d50_0000,
            0,
            "_other_field",
            0x30,
        );
        install_object(
            &mut mem,
            holder_addr,
            0x40,
            holder_vtable,
            holder_class_addr,
            &holder_class_bytes,
            &[],
        );

        let result = read_battlefield_arena_ids(&offsets, holder_addr, |a, l| mem.read(a, l));
        assert_eq!(result, None);
    }
}
