//! Walk Chain 2 — `MatchSceneManager` to the per-seat / per-zone
//! `ICardHolder` pointer map.
//!
//! Pointer chain (verified against MTGA build `Fri Apr 11 17:22:20 2025`,
//! see `mtga-duress/experiments/spikes/spike16_match_manager/FINDING.md`
//! — Chain 2 section):
//!
//! ```text
//! MatchSceneManager
//!   .Instance                         (STATIC field)
//!     ._gameManager                   -> GameManager
//!       .CardHolderManager            -> CardHolderManager
//!         ._provider                  -> MutableCardHolderProvider
//!           .PlayerTypeMap            -> Dictionary<int, Dictionary<int, ICardHolder>>
//! ```
//!
//! The outer dictionary is keyed by seat (GREPlayerNum: LocalPlayer,
//! Opponent, Teammate, …); the inner dictionary is keyed by zone
//! (CardHolderType: Library, Hand, Battlefield, Graveyard, Exile,
//! Stack, Command, …) and yields a pointer to the concrete
//! `ICardHolder` instance for that (seat, zone) pair.
//!
//! This module returns the resolved seat→zone→holder pointer map.
//! Drilling into a holder to extract `BaseCDC.BaseGrpId` lives in
//! a downstream module (TBD — needs live-spike data on the holder
//! subclass shapes).
//!
//! ## Tear-down behaviour
//!
//! `MatchSceneManager.Instance` becomes NULL once a match ends and
//! the duel scene is unloaded. This is the signal `Scry2.LiveState`
//! uses to transition POLLING → WINDING_DOWN. Callers should treat
//! `find_scene_singleton` returning `None` as "no active match" —
//! a normal state, not an error.

use std::collections::BTreeMap;

use super::dict_kv::{self, DictPtrEntry};
use super::field;
use super::mono::{self, MonoOffsets};

/// Outer-dict scheme: seat → list of zone-holder pairs.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SeatZoneMap {
    pub seats: Vec<SeatHolders>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SeatHolders {
    pub seat_id: i32,
    pub zones: Vec<ZoneHolder>,
}

#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct ZoneHolder {
    pub zone_id: i32,
    pub holder_addr: u64,
}

/// Resolve `MatchSceneManager.Instance` (the static singleton) given
/// the class addr + class-def bytes of `MatchSceneManager` and the
/// active root `MonoDomain`. Returns the singleton address, or `None`
/// when no match is active.
pub fn find_scene_singleton<F>(
    offsets: &MonoOffsets,
    scene_class_addr: u64,
    scene_class_bytes: &[u8],
    domain_addr: u64,
    read_mem: F,
) -> Option<u64>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let instance_field =
        field::find_field_by_name(offsets, scene_class_bytes, "Instance", read_mem)?;
    if !instance_field.is_static || instance_field.offset < 0 {
        return None;
    }
    let storage =
        super::vtable::static_storage_base(offsets, scene_class_addr, domain_addr, read_mem)?;
    let static_addr = storage.checked_add(instance_field.offset as u64)?;
    let bytes = read_mem(static_addr, 8)?;
    let ptr = mono::read_u64(&bytes, 0, 0)?;
    if ptr == 0 {
        None
    } else {
        Some(ptr)
    }
}

/// Walk from a resolved scene singleton to its inner `PlayerTypeMap`
/// dictionary. Returns the dictionary's address and runtime-class
/// blob (needed for `_entries` field resolution).
///
/// Chain: `_gameManager` → `CardHolderManager` → `_provider` →
/// `PlayerTypeMap`.
pub fn walk_to_player_type_map<F>(
    offsets: &MonoOffsets,
    scene_addr: u64,
    read_mem: F,
) -> Option<(u64, Vec<u8>)>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let scene_class_bytes = read_object_class_def(scene_addr, &read_mem)?;
    let game_manager = read_instance_pointer(
        offsets,
        &scene_class_bytes,
        scene_addr,
        "_gameManager",
        &read_mem,
    )?;

    let gm_class_bytes = read_object_class_def(game_manager, &read_mem)?;
    let chm_addr = read_instance_pointer(
        offsets,
        &gm_class_bytes,
        game_manager,
        "CardHolderManager",
        &read_mem,
    )?;

    let chm_class_bytes = read_object_class_def(chm_addr, &read_mem)?;
    let provider_addr =
        read_instance_pointer(offsets, &chm_class_bytes, chm_addr, "_provider", &read_mem)?;

    let provider_class_bytes = read_object_class_def(provider_addr, &read_mem)?;
    let ptm_addr = read_instance_pointer(
        offsets,
        &provider_class_bytes,
        provider_addr,
        "PlayerTypeMap",
        &read_mem,
    )?;

    let ptm_class_bytes = read_object_class_def(ptm_addr, &read_mem)?;
    Some((ptm_addr, ptm_class_bytes))
}

/// Read the seat→zone→holder map by walking the outer
/// `Dictionary<int, Dictionary<int, ICardHolder>>` and, for each
/// outer entry, the inner `Dictionary<int, ICardHolder>`.
///
/// Inner-dict reads that fail (null `_entries`, unresolvable field,
/// etc.) leave the seat present with an empty zones list — the
/// caller can decide how to surface partial reads. Outer-dict failure
/// returns `None`.
pub fn read_seat_zone_map<F>(
    offsets: &MonoOffsets,
    ptm_addr: u64,
    ptm_class_bytes: &[u8],
    read_mem: F,
) -> Option<SeatZoneMap>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let outer_entries_addr =
        dict_kv::entries_array_addr(offsets, ptm_class_bytes, ptm_addr, &read_mem)?;
    let outer_count = super::instance_field::read_instance_i32(
        offsets,
        ptm_class_bytes,
        ptm_addr,
        "_count",
        &read_mem,
    )
    .map(|n| n.max(0) as usize);
    let outer_entries =
        dict_kv::read_int_ptr_entries(offsets, outer_entries_addr, outer_count, read_mem)?;

    // Group by seat in deterministic order. The dictionary itself is
    // unordered, so sorting by key gives a stable result regardless of
    // hash bucket placement.
    let mut by_seat: BTreeMap<i32, Vec<ZoneHolder>> = BTreeMap::new();

    for DictPtrEntry {
        key: seat,
        value: inner_dict_addr,
    } in outer_entries
    {
        let zones = if inner_dict_addr == 0 {
            Vec::new()
        } else {
            read_inner_zone_map(offsets, inner_dict_addr, &read_mem).unwrap_or_default()
        };
        by_seat.insert(seat, zones);
    }

    let seats = by_seat
        .into_iter()
        .map(|(seat_id, zones)| SeatHolders { seat_id, zones })
        .collect();
    Some(SeatZoneMap { seats })
}

/// Read one inner `Dictionary<int, ICardHolder>` at `inner_dict_addr`.
fn read_inner_zone_map<F>(
    offsets: &MonoOffsets,
    inner_dict_addr: u64,
    read_mem: &F,
) -> Option<Vec<ZoneHolder>>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let class_bytes = read_object_class_def(inner_dict_addr, read_mem)?;
    let entries_addr =
        dict_kv::entries_array_addr(offsets, &class_bytes, inner_dict_addr, read_mem)?;
    let inner_count = super::instance_field::read_instance_i32(
        offsets,
        &class_bytes,
        inner_dict_addr,
        "_count",
        &read_mem,
    )
    .map(|n| n.max(0) as usize);
    let entries = dict_kv::read_int_ptr_entries(offsets, entries_addr, inner_count, read_mem)?;

    let mut by_zone: BTreeMap<i32, u64> = BTreeMap::new();
    for DictPtrEntry {
        key: zone,
        value: holder,
    } in entries
    {
        // Keep the entry even if holder is null — caller may want to
        // know the zone was registered but no card holder yet bound.
        by_zone.insert(zone, holder);
    }
    Some(
        by_zone
            .into_iter()
            .map(|(zone_id, holder_addr)| ZoneHolder {
                zone_id,
                holder_addr,
            })
            .collect(),
    )
}

use super::object::{read_instance_pointer, read_runtime_class_bytes as read_object_class_def};

#[cfg(test)]
mod tests {
    use super::*;
    use crate::walker::mono::MONO_CLASS_FIELD_SIZE;
    use crate::walker::test_support::{make_class_def, make_type_block, FakeMem};

    fn make_field_entry(name_ptr: u64, type_ptr: u64, offset: i32) -> Vec<u8> {
        crate::walker::test_support::make_field_entry(name_ptr, type_ptr, 0, offset)
    }

    /// Build a class with the listed `(name, offset, attrs)` fields.
    /// Returns the class_bytes blob; populates FakeMem with the
    /// fields-array, name strings, and type blocks.
    fn build_class(
        mem: &mut FakeMem,
        fields_array_addr: u64,
        names_base: u64,
        types_base: u64,
        fields: &[(&str, i32, u16)],
    ) -> Vec<u8> {
        let mut entry_blob = Vec::with_capacity(fields.len() * MONO_CLASS_FIELD_SIZE);
        for (i, (name, offset, attrs)) in fields.iter().enumerate() {
            let name_ptr = names_base + (i as u64) * 0x80;
            let type_ptr = types_base + (i as u64) * 0x20;
            entry_blob.extend_from_slice(&make_field_entry(name_ptr, type_ptr, *offset));
            let mut name_buf = name.as_bytes().to_vec();
            name_buf.push(0);
            mem.add(name_ptr, name_buf);
            mem.add(type_ptr, make_type_block(*attrs));
        }
        mem.add(fields_array_addr, entry_blob);
        make_class_def(fields_array_addr, fields.len() as u32)
    }

    /// Install an object whose `vtable.klass` points to `class_bytes`.
    fn install_object_with_class(
        mem: &mut FakeMem,
        object_addr: u64,
        object_payload_size: usize,
        vtable_addr: u64,
        class_addr: u64,
        class_bytes: Vec<u8>,
    ) {
        let mut payload = vec![0u8; object_payload_size.max(0x10)];
        payload[0..8].copy_from_slice(&vtable_addr.to_le_bytes());
        mem.add(object_addr, payload);
        let mut vt = vec![0u8; 0x50];
        vt[0..8].copy_from_slice(&class_addr.to_le_bytes());
        mem.add(vtable_addr, vt);
        mem.add(class_addr, class_bytes);
    }

    /// Stamp a u64 ptr at `field_offset` of a given object's payload
    /// in-place by replacing the block.
    #[allow(clippy::too_many_arguments)]
    fn install_object_with_class_and_stamps(
        mem: &mut FakeMem,
        object_addr: u64,
        object_payload_size: usize,
        vtable_addr: u64,
        class_addr: u64,
        class_bytes: Vec<u8>,
        stamps: &[(i32, u64)],
    ) {
        let mut payload = vec![0u8; object_payload_size.max(0x10)];
        payload[0..8].copy_from_slice(&vtable_addr.to_le_bytes());
        for (off, ptr) in stamps {
            let off = *off as usize;
            payload[off..off + 8].copy_from_slice(&ptr.to_le_bytes());
        }
        mem.add(object_addr, payload);
        let mut vt = vec![0u8; 0x50];
        vt[0..8].copy_from_slice(&class_addr.to_le_bytes());
        mem.add(vtable_addr, vt);
        mem.add(class_addr, class_bytes);
    }

    fn make_array_header(capacity: u64) -> Vec<u8> {
        let offsets = MonoOffsets::mtga_default();
        let mut v = vec![0u8; offsets.array_vector];
        v[offsets.array_max_length..offsets.array_max_length + 8]
            .copy_from_slice(&capacity.to_le_bytes());
        v
    }

    fn used_ptr_entry(key: i32, value: u64) -> [u8; 24] {
        let mut v = [0u8; 24];
        v[0..4].copy_from_slice(&(key & 0x7FFF_FFFF).to_le_bytes());
        v[4..8].copy_from_slice(&(-1i32).to_le_bytes());
        v[8..12].copy_from_slice(&key.to_le_bytes());
        v[16..24].copy_from_slice(&value.to_le_bytes());
        v
    }

    #[allow(clippy::too_many_arguments)]
    fn install_dict_with_entries(
        mem: &mut FakeMem,
        dict_class_addr: u64,
        dict_class_bytes_template_offset: i32,
        names_base: u64,
        types_base: u64,
        dict_addr: u64,
        dict_vtable_addr: u64,
        entries_array_addr: u64,
        entries: &[[u8; 24]],
    ) {
        // Build a Dictionary class with one field "_entries" at
        // offset `dict_class_bytes_template_offset`.
        let dict_class_bytes = build_class(
            mem,
            dict_class_addr + 0x10000,
            names_base,
            types_base,
            &[("_entries", dict_class_bytes_template_offset, 0)],
        );

        // Install the dict object with vtable.klass → dict class.
        install_object_with_class_and_stamps(
            mem,
            dict_addr,
            0x80,
            dict_vtable_addr,
            dict_class_addr,
            dict_class_bytes,
            &[(dict_class_bytes_template_offset, entries_array_addr)],
        );

        // Install the array header + entries blob.
        let mut header = make_array_header(entries.len() as u64);
        let offsets = MonoOffsets::mtga_default();
        // Array header at array_addr; entry blob at array_addr + array_vector.
        let mut entry_bytes = Vec::with_capacity(entries.len() * 24);
        for e in entries {
            entry_bytes.extend_from_slice(e);
        }
        // Pad header to full size if needed.
        header.resize(offsets.array_vector, 0);
        mem.add(entries_array_addr, header);
        mem.add(
            entries_array_addr + offsets.array_vector as u64,
            entry_bytes,
        );
    }

    #[test]
    fn find_scene_singleton_returns_none_when_field_missing() {
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();
        // Class with no Instance field at all.
        let class_bytes = build_class(&mut mem, 0x1000, 0x2000, 0x3000, &[("Other", 0x10, 0)]);

        let result = find_scene_singleton(&offsets, 0xc0_0000, &class_bytes, 0xd0_0000, |a, l| {
            mem.read(a, l)
        });
        assert_eq!(result, None);
    }

    #[test]
    fn find_scene_singleton_returns_none_when_instance_is_instance_field() {
        // Defensive — Instance must be STATIC; reject if seen as instance.
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();
        // Build a class whose Instance field is INSTANCE (attrs without 0x10).
        let class_bytes = build_class(&mut mem, 0x1000, 0x2000, 0x3000, &[("Instance", 0x18, 0x6)]);

        let result = find_scene_singleton(&offsets, 0xc0_0000, &class_bytes, 0xd0_0000, |a, l| {
            mem.read(a, l)
        });
        assert_eq!(result, None);
    }

    #[test]
    fn read_seat_zone_map_groups_holders_by_seat_and_zone() -> Result<(), String> {
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();

        // Inner dict for seat 0: {3 → 0xaaaa, 7 → 0xbbbb}.
        let inner_a_addr: u64 = 0x100_0000;
        let inner_a_vtable: u64 = 0x100_1000;
        let inner_a_class: u64 = 0x100_2000;
        let inner_a_entries_array: u64 = 0x100_3000;
        let inner_a_entries = [used_ptr_entry(3, 0xaaaa), used_ptr_entry(7, 0xbbbb)];
        install_dict_with_entries(
            &mut mem,
            inner_a_class,
            0x40,
            0x100_4000,
            0x100_5000,
            inner_a_addr,
            inner_a_vtable,
            inner_a_entries_array,
            &inner_a_entries,
        );

        // Inner dict for seat 1: {4 → 0xcccc}.
        let inner_b_addr: u64 = 0x200_0000;
        let inner_b_vtable: u64 = 0x200_1000;
        let inner_b_class: u64 = 0x200_2000;
        let inner_b_entries_array: u64 = 0x200_3000;
        let inner_b_entries = [used_ptr_entry(4, 0xcccc)];
        install_dict_with_entries(
            &mut mem,
            inner_b_class,
            0x40,
            0x200_4000,
            0x200_5000,
            inner_b_addr,
            inner_b_vtable,
            inner_b_entries_array,
            &inner_b_entries,
        );

        // Outer dict (PlayerTypeMap): {0 → inner_a_addr, 1 → inner_b_addr}.
        let ptm_addr: u64 = 0x300_0000;
        let ptm_vtable: u64 = 0x300_1000;
        let ptm_class: u64 = 0x300_2000;
        let ptm_entries_array: u64 = 0x300_3000;
        let ptm_entries = [
            used_ptr_entry(0, inner_a_addr),
            used_ptr_entry(1, inner_b_addr),
        ];
        install_dict_with_entries(
            &mut mem,
            ptm_class,
            0x50,
            0x300_4000,
            0x300_5000,
            ptm_addr,
            ptm_vtable,
            ptm_entries_array,
            &ptm_entries,
        );

        // Read PTM class bytes — same construct used by walker production code.
        let ptm_class_bytes = mem
            .read(ptm_class, crate::walker::mono::CLASS_DEF_BLOB_LEN)
            .ok_or("read ptm class bytes")?;

        let result =
            read_seat_zone_map(&offsets, ptm_addr, &ptm_class_bytes, |a, l| mem.read(a, l))
                .ok_or("read_seat_zone_map should return Some")?;

        assert_eq!(result.seats.len(), 2);

        let seat_a = &result.seats[0];
        assert_eq!(seat_a.seat_id, 0);
        assert_eq!(seat_a.zones.len(), 2);
        assert_eq!(
            seat_a.zones[0],
            ZoneHolder {
                zone_id: 3,
                holder_addr: 0xaaaa
            }
        );
        assert_eq!(
            seat_a.zones[1],
            ZoneHolder {
                zone_id: 7,
                holder_addr: 0xbbbb
            }
        );

        let seat_b = &result.seats[1];
        assert_eq!(seat_b.seat_id, 1);
        assert_eq!(seat_b.zones.len(), 1);
        assert_eq!(
            seat_b.zones[0],
            ZoneHolder {
                zone_id: 4,
                holder_addr: 0xcccc
            }
        );
        Ok(())
    }

    #[test]
    fn read_seat_zone_map_returns_empty_zones_for_null_inner_dict() -> Result<(), String> {
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();

        // Outer dict where seat 99 maps to a null inner-dict pointer.
        let ptm_addr: u64 = 0x400_0000;
        let ptm_vtable: u64 = 0x400_1000;
        let ptm_class: u64 = 0x400_2000;
        let ptm_entries_array: u64 = 0x400_3000;
        let ptm_entries = [used_ptr_entry(99, 0)];
        install_dict_with_entries(
            &mut mem,
            ptm_class,
            0x50,
            0x400_4000,
            0x400_5000,
            ptm_addr,
            ptm_vtable,
            ptm_entries_array,
            &ptm_entries,
        );

        let ptm_class_bytes = mem
            .read(ptm_class, crate::walker::mono::CLASS_DEF_BLOB_LEN)
            .ok_or("read ptm class bytes")?;

        let result =
            read_seat_zone_map(&offsets, ptm_addr, &ptm_class_bytes, |a, l| mem.read(a, l))
                .ok_or("should return Some")?;

        assert_eq!(result.seats.len(), 1);
        assert_eq!(result.seats[0].seat_id, 99);
        assert!(result.seats[0].zones.is_empty());
        Ok(())
    }

    #[test]
    fn walk_to_player_type_map_chains_through_managers() -> Result<(), String> {
        // End-to-end: scene -> _gameManager -> CardHolderManager
        // -> _provider -> PlayerTypeMap (just confirms the addr; PTM's
        // class-bytes parse is verified in the bigger test above).
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();

        let scene_addr: u64 = 0x500_0000;
        let scene_vtable: u64 = 0x500_1000;
        let scene_class: u64 = 0x500_2000;
        let game_manager_addr: u64 = 0x600_0000;
        let game_manager_vtable: u64 = 0x600_1000;
        let game_manager_class: u64 = 0x600_2000;
        let chm_addr: u64 = 0x700_0000;
        let chm_vtable: u64 = 0x700_1000;
        let chm_class: u64 = 0x700_2000;
        let provider_addr: u64 = 0x800_0000;
        let provider_vtable: u64 = 0x800_1000;
        let provider_class: u64 = 0x800_2000;
        let ptm_addr: u64 = 0x900_0000;
        let ptm_vtable: u64 = 0x900_1000;
        let ptm_class: u64 = 0x900_2000;

        let scene_class_bytes = build_class(
            &mut mem,
            0x500_3000,
            0x500_4000,
            0x500_5000,
            &[("_gameManager", 0x20, 0)],
        );
        install_object_with_class_and_stamps(
            &mut mem,
            scene_addr,
            0x80,
            scene_vtable,
            scene_class,
            scene_class_bytes,
            &[(0x20, game_manager_addr)],
        );

        let gm_class_bytes = build_class(
            &mut mem,
            0x600_3000,
            0x600_4000,
            0x600_5000,
            &[("CardHolderManager", 0x30, 0)],
        );
        install_object_with_class_and_stamps(
            &mut mem,
            game_manager_addr,
            0x80,
            game_manager_vtable,
            game_manager_class,
            gm_class_bytes,
            &[(0x30, chm_addr)],
        );

        let chm_class_bytes = build_class(
            &mut mem,
            0x700_3000,
            0x700_4000,
            0x700_5000,
            &[("_provider", 0x40, 0)],
        );
        install_object_with_class_and_stamps(
            &mut mem,
            chm_addr,
            0x80,
            chm_vtable,
            chm_class,
            chm_class_bytes,
            &[(0x40, provider_addr)],
        );

        let provider_class_bytes = build_class(
            &mut mem,
            0x800_3000,
            0x800_4000,
            0x800_5000,
            &[("PlayerTypeMap", 0x50, 0)],
        );
        install_object_with_class_and_stamps(
            &mut mem,
            provider_addr,
            0x80,
            provider_vtable,
            provider_class,
            provider_class_bytes,
            &[(0x50, ptm_addr)],
        );

        // PTM is a Dictionary — install it so read_object_class_def
        // can read its runtime class. We don't read entries here.
        let ptm_class_bytes = build_class(
            &mut mem,
            0x900_3000,
            0x900_4000,
            0x900_5000,
            &[("_entries", 0x18, 0)],
        );
        install_object_with_class(
            &mut mem,
            ptm_addr,
            0x80,
            ptm_vtable,
            ptm_class,
            ptm_class_bytes,
        );

        let (got_ptm, _bytes) =
            walk_to_player_type_map(&offsets, scene_addr, |a, l| mem.read(a, l))
                .ok_or("walk should succeed")?;
        assert_eq!(got_ptm, ptm_addr);
        Ok(())
    }

    #[test]
    fn walk_to_player_type_map_stops_at_null_pointer_in_chain() {
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();

        let scene_addr: u64 = 0xa00_0000;
        let scene_vtable: u64 = 0xa00_1000;
        let scene_class: u64 = 0xa00_2000;

        let scene_class_bytes = build_class(
            &mut mem,
            0xa00_3000,
            0xa00_4000,
            0xa00_5000,
            &[("_gameManager", 0x20, 0)],
        );
        // _gameManager pointer slot left zero (null).
        install_object_with_class(
            &mut mem,
            scene_addr,
            0x80,
            scene_vtable,
            scene_class,
            scene_class_bytes,
        );

        let result = walk_to_player_type_map(&offsets, scene_addr, |a, l| mem.read(a, l));
        assert!(result.is_none());
    }
}
