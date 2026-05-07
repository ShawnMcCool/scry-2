//! Read MTGA's cosmetics inventory from memory.
//!
//! Chain (verified spike 22, MTGA build Fri Apr 11 17:22:20 2025; see
//! `mtga-duress/experiments/spikes/spike22_papa_managers/FINDING.md`):
//!
//! ```text
//! PAPA._instance                                       (resolved upstream)
//!   .<CosmeticsProvider>k__BackingField                -> CosmeticsProvider
//!     ._availableCosmetics                             -> CosmeticsClient (master list)
//!     ._playerOwnedCosmetics                           -> CosmeticsClient (player owns)
//!     ._vanitySelections                               -> ClientVanitySelectionsV3
//!
//! CosmeticsClient (same shape for available + owned):
//!   .ArtStyles, .Avatars, .Pets, .Sleeves, .Emotes, .Titles : List<T>
//!
//! ClientVanitySelectionsV3:
//!   .avatarSelection      : MonoString *
//!   .cardBackSelection    : MonoString *
//!   .petSelection         : MonoString *  (NULL when no pet equipped)
//!   .titleSelection       : MonoString *
//! ```
//!
//! For v1 we read only **list sizes** (counts) on `CosmeticsClient`
//! rather than enumerating individual cosmetic IDs. The "X owned of Y
//! total" surface is the cheapest user-visible read, and per-item
//! enumeration would balloon read budget without obvious payoff. Same
//! for `ClientVanitySelectionsV3.emoteSelections` — that's a `List<T>`
//! and we skip it; only the four scalar string slots are read.
//!
//! Field names are resolved via [`super::field::find_field_by_name`] /
//! `_in_chain` — offsets in the FINDING are diagnostic, not constants.

use super::instance_field;
use super::list_t;
use super::mono::MonoOffsets;
use super::object;

/// Cap on cosmetic-id MonoString reads. MTGA selection tokens look
/// like `"Avatar_Cosmetic_Niv_Mizzet_Reborn"` — under 64 chars in
/// practice; 128 leaves headroom while bounding torn-read damage.
const MAX_STRING_CHARS: usize = 128;

const PAPA_ANCHOR_FIELD: &str = "<CosmeticsProvider>k__BackingField";

const AVAILABLE_FIELD: &str = "_availableCosmetics";
const OWNED_FIELD: &str = "_playerOwnedCosmetics";
const VANITY_FIELD: &str = "_vanitySelections";

const ART_STYLES_FIELD: &str = "ArtStyles";
const AVATARS_FIELD: &str = "Avatars";
const PETS_FIELD: &str = "Pets";
const SLEEVES_FIELD: &str = "Sleeves";
const EMOTES_FIELD: &str = "Emotes";
const TITLES_FIELD: &str = "Titles";

const AVATAR_SELECTION_FIELD: &str = "avatarSelection";
const CARD_BACK_SELECTION_FIELD: &str = "cardBackSelection";
const PET_SELECTION_FIELD: &str = "petSelection";
const TITLE_SELECTION_FIELD: &str = "titleSelection";

/// Per-category counts on a `CosmeticsClient`. All defaults to `0`
/// when the field can't be resolved.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CosmeticCounts {
    pub art_styles: i32,
    pub avatars: i32,
    pub pets: i32,
    pub sleeves: i32,
    pub emotes: i32,
    pub titles: i32,
}

/// Currently-equipped cosmetic identifiers. `pet` is `None` when no
/// pet is equipped (the typical case for non-pet-collecting players).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct VanityEquipped {
    pub avatar: Option<String>,
    pub card_back: Option<String>,
    pub pet: Option<String>,
    pub title: Option<String>,
}

/// One full cosmetics-summary read.
///
/// `None` (returned by [`from_papa_singleton`]) when the chain itself
/// is unreachable — typically pre-login MTGA. Otherwise both
/// `available` and `owned` are populated; counts default to zero on
/// per-field failure rather than dropping the whole struct.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CosmeticsSummary {
    pub available: CosmeticCounts,
    pub owned: CosmeticCounts,
    pub equipped: VanityEquipped,
}

/// Walk PAPA → CosmeticsProvider → {available, owned, vanity} and
/// return the per-category counts plus equipped-slot strings.
///
/// Returns `None` only when the chain hops short (PAPA →
/// CosmeticsProvider null, or CosmeticsProvider can't be class-
/// resolved). Per-sub-chain failures (e.g. `_availableCosmetics`
/// null) collapse into zeroed `CosmeticCounts` rather than dropping
/// the whole struct.
pub fn from_papa_singleton<F>(
    offsets: &MonoOffsets,
    papa_singleton_addr: u64,
    papa_class_bytes: &[u8],
    read_mem: F,
) -> Option<CosmeticsSummary>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let provider_addr = object::read_instance_pointer(
        offsets,
        papa_class_bytes,
        papa_singleton_addr,
        PAPA_ANCHOR_FIELD,
        &read_mem,
    )?;
    let provider_class_bytes = object::read_runtime_class_bytes(provider_addr, &read_mem)?;

    let available =
        read_cosmetic_counts(offsets, provider_addr, &provider_class_bytes, AVAILABLE_FIELD, &read_mem);
    let owned =
        read_cosmetic_counts(offsets, provider_addr, &provider_class_bytes, OWNED_FIELD, &read_mem);
    let equipped = read_vanity_equipped(offsets, provider_addr, &provider_class_bytes, &read_mem);

    Some(CosmeticsSummary {
        available,
        owned,
        equipped,
    })
}

/// Read the six `List<T>._size` fields off a `CosmeticsClient`
/// reachable from `provider_addr.<sub_field>`. Returns zeroed counts
/// if the sub-pointer is null or its class can't be resolved.
fn read_cosmetic_counts<F>(
    offsets: &MonoOffsets,
    provider_addr: u64,
    provider_class_bytes: &[u8],
    sub_field: &str,
    read_mem: &F,
) -> CosmeticCounts
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let Some(client_addr) =
        object::read_instance_pointer(offsets, provider_class_bytes, provider_addr, sub_field, read_mem)
    else {
        return CosmeticCounts::default();
    };
    let Some(client_class_bytes) = object::read_runtime_class_bytes(client_addr, read_mem) else {
        return CosmeticCounts::default();
    };

    CosmeticCounts {
        art_styles: list_size(offsets, client_addr, &client_class_bytes, ART_STYLES_FIELD, read_mem),
        avatars: list_size(offsets, client_addr, &client_class_bytes, AVATARS_FIELD, read_mem),
        pets: list_size(offsets, client_addr, &client_class_bytes, PETS_FIELD, read_mem),
        sleeves: list_size(offsets, client_addr, &client_class_bytes, SLEEVES_FIELD, read_mem),
        emotes: list_size(offsets, client_addr, &client_class_bytes, EMOTES_FIELD, read_mem),
        titles: list_size(offsets, client_addr, &client_class_bytes, TITLES_FIELD, read_mem),
    }
}

/// Resolve a `List<T>` field on `client_addr` and return its `_size`.
/// Defaults to `0` for null lists / unresolvable classes — the
/// caller's downstream display ("0 / N") is benign.
fn list_size<F>(
    offsets: &MonoOffsets,
    client_addr: u64,
    client_class_bytes: &[u8],
    field_name: &str,
    read_mem: &F,
) -> i32
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let Some(list_addr) =
        object::read_instance_pointer(offsets, client_class_bytes, client_addr, field_name, read_mem)
    else {
        return 0;
    };
    let Some(list_class_bytes) = object::read_runtime_class_bytes(list_addr, read_mem) else {
        return 0;
    };
    list_t::read_size(offsets, &list_class_bytes, list_addr, read_mem).unwrap_or(0)
}

/// Read the four scalar slot-strings on `ClientVanitySelectionsV3`.
/// `pet` is the only one that's commonly null (no pet equipped); the
/// others default to `None` only on field-resolution failure.
fn read_vanity_equipped<F>(
    offsets: &MonoOffsets,
    provider_addr: u64,
    provider_class_bytes: &[u8],
    read_mem: &F,
) -> VanityEquipped
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let Some(vanity_addr) =
        object::read_instance_pointer(offsets, provider_class_bytes, provider_addr, VANITY_FIELD, read_mem)
    else {
        return VanityEquipped::default();
    };
    let Some(vanity_class_bytes) = object::read_runtime_class_bytes(vanity_addr, read_mem) else {
        return VanityEquipped::default();
    };

    VanityEquipped {
        avatar: instance_field::read_instance_string(
            offsets,
            &vanity_class_bytes,
            vanity_addr,
            AVATAR_SELECTION_FIELD,
            MAX_STRING_CHARS,
            read_mem,
        ),
        card_back: instance_field::read_instance_string(
            offsets,
            &vanity_class_bytes,
            vanity_addr,
            CARD_BACK_SELECTION_FIELD,
            MAX_STRING_CHARS,
            read_mem,
        ),
        pet: instance_field::read_instance_string(
            offsets,
            &vanity_class_bytes,
            vanity_addr,
            PET_SELECTION_FIELD,
            MAX_STRING_CHARS,
            read_mem,
        ),
        title: instance_field::read_instance_string(
            offsets,
            &vanity_class_bytes,
            vanity_addr,
            TITLE_SELECTION_FIELD,
            MAX_STRING_CHARS,
            read_mem,
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::walker::mono::MONO_CLASS_FIELD_SIZE;
    use crate::walker::test_support::{make_class_def, make_field_entry, make_type_block, FakeMem};

    type FieldSpec<'a> = (&'a str, i32);

    fn install_class_fields(
        mem: &mut FakeMem,
        fields_addr: u64,
        fields: &[FieldSpec<'_>],
    ) -> Vec<u8> {
        let names_base = fields_addr + 0x1_0000;
        let types_base = fields_addr + 0x2_0000;
        let mut entry_blob = Vec::with_capacity(fields.len() * MONO_CLASS_FIELD_SIZE);
        for (i, (name, offset)) in fields.iter().enumerate() {
            let name_ptr = names_base + (i as u64) * 0x80;
            let type_ptr = types_base + (i as u64) * 0x20;
            entry_blob.extend_from_slice(&make_field_entry(name_ptr, type_ptr, 0, *offset));
            let mut name_buf = name.as_bytes().to_vec();
            name_buf.push(0);
            mem.add(name_ptr, name_buf);
            mem.add(type_ptr, make_type_block(0));
        }
        mem.add(fields_addr, entry_blob);
        make_class_def(fields_addr, fields.len() as u32)
    }

    fn install_class_at(
        mem: &mut FakeMem,
        class_addr: u64,
        vtable_addr: u64,
        class_bytes: Vec<u8>,
    ) {
        mem.add(class_addr, class_bytes);
        let mut vt = vec![0u8; 0x10];
        vt[0..8].copy_from_slice(&class_addr.to_le_bytes());
        mem.add(vtable_addr, vt);
    }

    fn install_mono_string(mem: &mut FakeMem, addr: u64, s: &str) {
        let utf16: Vec<u16> = s.encode_utf16().collect();
        let mut hdr = vec![0u8; 0x14];
        hdr[0x10..0x14].copy_from_slice(&(utf16.len() as i32).to_le_bytes());
        mem.add(addr, hdr);
        let mut chars = Vec::with_capacity(utf16.len() * 2);
        for u in &utf16 {
            chars.extend_from_slice(&u.to_le_bytes());
        }
        mem.add(addr + 0x14, chars);
    }

    fn stamp_ptr(payload: &mut [u8], offset: i32, ptr: u64) {
        let off = offset as usize;
        payload[off..off + 8].copy_from_slice(&ptr.to_le_bytes());
    }

    fn stamp_i32(payload: &mut [u8], offset: i32, value: i32) {
        let off = offset as usize;
        payload[off..off + 4].copy_from_slice(&value.to_le_bytes());
    }

    /// Address layout for the test chain. Each region has 64 MiB
    /// headroom because `install_class_fields` plants names + types
    /// 0x1_0000 / 0x2_0000 above the supplied fields_addr.
    struct AddrPlan;

    impl AddrPlan {
        const PAPA_OBJECT: u64 = 0x0100_0000;
        const PAPA_CLASS_FIELDS: u64 = 0x0110_0000;

        const PROVIDER_OBJECT: u64 = 0x0500_0000;
        const PROVIDER_VTABLE: u64 = 0x0510_0000;
        const PROVIDER_CLASS: u64 = 0x0520_0000;
        const PROVIDER_CLASS_FIELDS: u64 = 0x0530_0000;

        // Two CosmeticsClient instances + their (shared) class.
        const CLIENT_CLASS: u64 = 0x0900_0000;
        const CLIENT_CLASS_FIELDS: u64 = 0x0910_0000;
        const CLIENT_VTABLE: u64 = 0x0920_0000;

        const AVAILABLE_OBJECT: u64 = 0x0a00_0000;
        const OWNED_OBJECT: u64 = 0x0b00_0000;

        // Per-list scaffolding. Six categories × two client objects
        // = 12 lists. Pack into a 0x100_0000-stride region per list.
        const LISTS_BASE: u64 = 0x1000_0000;
        const LIST_CLASS: u64 = 0x2000_0000;
        const LIST_CLASS_FIELDS: u64 = 0x2010_0000;
        const LIST_VTABLE: u64 = 0x2020_0000;

        // Vanity selections.
        const VANITY_OBJECT: u64 = 0x3000_0000;
        const VANITY_VTABLE: u64 = 0x3010_0000;
        const VANITY_CLASS: u64 = 0x3020_0000;
        const VANITY_CLASS_FIELDS: u64 = 0x3030_0000;

        const AVATAR_STRING: u64 = 0x3100_0000;
        const CARD_BACK_STRING: u64 = 0x3110_0000;
        const TITLE_STRING: u64 = 0x3120_0000;

        fn list_obj(client_kind: ClientKind, idx: usize) -> u64 {
            let kind_offset = match client_kind {
                ClientKind::Available => 0,
                ClientKind::Owned => 6,
            };
            Self::LISTS_BASE + ((kind_offset + idx) as u64) * 0x10_0000
        }
    }

    #[derive(Copy, Clone)]
    enum ClientKind {
        Available,
        Owned,
    }

    /// Build a synthetic chain mirroring the production layout.
    /// `available_sizes` and `owned_sizes` are 6-tuples in the
    /// CosmeticsClient field order: ArtStyles, Avatars, Pets,
    /// Sleeves, Emotes, Titles.
    #[allow(clippy::too_many_arguments)]
    fn build_chain(
        mem: &mut FakeMem,
        available_sizes: [i32; 6],
        owned_sizes: [i32; 6],
        equipped_avatar: Option<&str>,
        equipped_card_back: Option<&str>,
        equipped_pet: Option<&str>,
        equipped_title: Option<&str>,
    ) -> (MonoOffsets, u64, Vec<u8>) {
        let offsets = MonoOffsets::mtga_default();

        // PAPA — one anchor field.
        let papa_anchor_offset = 0x10i32;
        let papa_class_bytes = install_class_fields(
            mem,
            AddrPlan::PAPA_CLASS_FIELDS,
            &[(PAPA_ANCHOR_FIELD, papa_anchor_offset)],
        );
        let mut papa_payload = vec![0u8; 0x40];
        stamp_ptr(&mut papa_payload, papa_anchor_offset, AddrPlan::PROVIDER_OBJECT);
        mem.add(AddrPlan::PAPA_OBJECT, papa_payload);

        // CosmeticsProvider — three sub-pointers.
        let avail_off = 0x10i32;
        let owned_off = 0x18i32;
        let vanity_off = 0x20i32;
        let provider_class_bytes = install_class_fields(
            mem,
            AddrPlan::PROVIDER_CLASS_FIELDS,
            &[
                (AVAILABLE_FIELD, avail_off),
                (OWNED_FIELD, owned_off),
                (VANITY_FIELD, vanity_off),
            ],
        );
        install_class_at(
            mem,
            AddrPlan::PROVIDER_CLASS,
            AddrPlan::PROVIDER_VTABLE,
            provider_class_bytes,
        );
        let mut provider_payload = vec![0u8; 0x40];
        stamp_ptr(&mut provider_payload, 0, AddrPlan::PROVIDER_VTABLE);
        stamp_ptr(&mut provider_payload, avail_off, AddrPlan::AVAILABLE_OBJECT);
        stamp_ptr(&mut provider_payload, owned_off, AddrPlan::OWNED_OBJECT);
        stamp_ptr(&mut provider_payload, vanity_off, AddrPlan::VANITY_OBJECT);
        mem.add(AddrPlan::PROVIDER_OBJECT, provider_payload);

        // Shared CosmeticsClient class — six list fields.
        let art_off = 0x10i32;
        let avatars_off = 0x18i32;
        let pets_off = 0x20i32;
        let sleeves_off = 0x28i32;
        let emotes_off = 0x30i32;
        let titles_off = 0x38i32;
        let client_class_bytes = install_class_fields(
            mem,
            AddrPlan::CLIENT_CLASS_FIELDS,
            &[
                (ART_STYLES_FIELD, art_off),
                (AVATARS_FIELD, avatars_off),
                (PETS_FIELD, pets_off),
                (SLEEVES_FIELD, sleeves_off),
                (EMOTES_FIELD, emotes_off),
                (TITLES_FIELD, titles_off),
            ],
        );
        install_class_at(
            mem,
            AddrPlan::CLIENT_CLASS,
            AddrPlan::CLIENT_VTABLE,
            client_class_bytes,
        );

        // Shared List<T> class — _items @ 0x10 (unused here), _size @ 0x18.
        let list_class_bytes = install_class_fields(
            mem,
            AddrPlan::LIST_CLASS_FIELDS,
            &[("_items", 0x10), ("_size", 0x18)],
        );
        install_class_at(
            mem,
            AddrPlan::LIST_CLASS,
            AddrPlan::LIST_VTABLE,
            list_class_bytes,
        );

        // Helper to stamp a CosmeticsClient instance with its six lists.
        let mut emit_client = |client_addr: u64, kind: ClientKind, sizes: [i32; 6]| {
            let mut client_payload = vec![0u8; 0x80];
            stamp_ptr(&mut client_payload, 0, AddrPlan::CLIENT_VTABLE);

            for (idx, (offset, size)) in [
                (art_off, sizes[0]),
                (avatars_off, sizes[1]),
                (pets_off, sizes[2]),
                (sleeves_off, sizes[3]),
                (emotes_off, sizes[4]),
                (titles_off, sizes[5]),
            ]
            .into_iter()
            .enumerate()
            {
                let list_addr = AddrPlan::list_obj(kind, idx);
                stamp_ptr(&mut client_payload, offset, list_addr);

                let mut list_payload = vec![0u8; 0x30];
                stamp_ptr(&mut list_payload, 0, AddrPlan::LIST_VTABLE);
                stamp_i32(&mut list_payload, 0x18, size);
                mem.add(list_addr, list_payload);
            }
            mem.add(client_addr, client_payload);
        };

        emit_client(AddrPlan::AVAILABLE_OBJECT, ClientKind::Available, available_sizes);
        emit_client(AddrPlan::OWNED_OBJECT, ClientKind::Owned, owned_sizes);

        // ClientVanitySelectionsV3 — four scalar string slots.
        let avatar_off = 0x10i32;
        let card_back_off = 0x18i32;
        let pet_off = 0x20i32;
        let title_off = 0x30i32;
        let vanity_class_bytes = install_class_fields(
            mem,
            AddrPlan::VANITY_CLASS_FIELDS,
            &[
                (AVATAR_SELECTION_FIELD, avatar_off),
                (CARD_BACK_SELECTION_FIELD, card_back_off),
                (PET_SELECTION_FIELD, pet_off),
                (TITLE_SELECTION_FIELD, title_off),
            ],
        );
        install_class_at(
            mem,
            AddrPlan::VANITY_CLASS,
            AddrPlan::VANITY_VTABLE,
            vanity_class_bytes,
        );

        let mut vanity_payload = vec![0u8; 0x80];
        stamp_ptr(&mut vanity_payload, 0, AddrPlan::VANITY_VTABLE);
        if let Some(s) = equipped_avatar {
            install_mono_string(mem, AddrPlan::AVATAR_STRING, s);
            stamp_ptr(&mut vanity_payload, avatar_off, AddrPlan::AVATAR_STRING);
        }
        if let Some(s) = equipped_card_back {
            install_mono_string(mem, AddrPlan::CARD_BACK_STRING, s);
            stamp_ptr(&mut vanity_payload, card_back_off, AddrPlan::CARD_BACK_STRING);
        }
        // pet stays NULL when None — typical case.
        if let Some(_s) = equipped_pet {
            // Reserved for future tests.
        }
        if let Some(s) = equipped_title {
            install_mono_string(mem, AddrPlan::TITLE_STRING, s);
            stamp_ptr(&mut vanity_payload, title_off, AddrPlan::TITLE_STRING);
        }
        mem.add(AddrPlan::VANITY_OBJECT, vanity_payload);

        (offsets, AddrPlan::PAPA_OBJECT, papa_class_bytes)
    }

    #[test]
    fn reads_available_owned_counts_and_equipped_strings() {
        let mut mem = FakeMem::default();
        let (offsets, papa_addr, papa_class_bytes) = build_chain(
            &mut mem,
            [5_000, 200, 50, 100, 60, 250],
            [124, 12, 8, 5, 3, 7],
            Some("Avatar_Cosmetic_001"),
            Some("CardBack_Default"),
            None,
            Some("Title_Champion"),
        );

        let summary =
            from_papa_singleton(&offsets, papa_addr, &papa_class_bytes, |a, l| mem.read(a, l))
                .expect("chain should resolve");

        assert_eq!(
            summary.available,
            CosmeticCounts {
                art_styles: 5_000,
                avatars: 200,
                pets: 50,
                sleeves: 100,
                emotes: 60,
                titles: 250,
            }
        );
        assert_eq!(
            summary.owned,
            CosmeticCounts {
                art_styles: 124,
                avatars: 12,
                pets: 8,
                sleeves: 5,
                emotes: 3,
                titles: 7,
            }
        );
        assert_eq!(
            summary.equipped,
            VanityEquipped {
                avatar: Some("Avatar_Cosmetic_001".to_string()),
                card_back: Some("CardBack_Default".to_string()),
                pet: None,
                title: Some("Title_Champion".to_string()),
            }
        );
    }

    #[test]
    fn returns_none_when_provider_pointer_is_null() {
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();

        let papa_anchor_offset = 0x10i32;
        let papa_class_bytes = install_class_fields(
            &mut mem,
            AddrPlan::PAPA_CLASS_FIELDS,
            &[(PAPA_ANCHOR_FIELD, papa_anchor_offset)],
        );
        let papa_payload = vec![0u8; 0x40]; // anchor stays 0.
        mem.add(AddrPlan::PAPA_OBJECT, papa_payload);

        let summary = from_papa_singleton(
            &offsets,
            AddrPlan::PAPA_OBJECT,
            &papa_class_bytes,
            |a, l| mem.read(a, l),
        );
        assert!(summary.is_none(), "pre-login chain should be None");
    }

    #[test]
    fn zero_counts_when_a_list_field_is_absent() {
        // CosmeticsClient with five fields — Pets is missing entirely.
        // The walker should default Pets to 0 without skipping the
        // whole struct.
        let mut mem = FakeMem::default();
        let offsets = MonoOffsets::mtga_default();

        let papa_anchor_offset = 0x10i32;
        let papa_class_bytes = install_class_fields(
            &mut mem,
            AddrPlan::PAPA_CLASS_FIELDS,
            &[(PAPA_ANCHOR_FIELD, papa_anchor_offset)],
        );
        let mut papa_payload = vec![0u8; 0x40];
        stamp_ptr(&mut papa_payload, papa_anchor_offset, AddrPlan::PROVIDER_OBJECT);
        mem.add(AddrPlan::PAPA_OBJECT, papa_payload);

        // Provider with only available + vanity (no owned slot — owned = default).
        let avail_off = 0x10i32;
        let vanity_off = 0x20i32;
        let provider_class_bytes = install_class_fields(
            &mut mem,
            AddrPlan::PROVIDER_CLASS_FIELDS,
            &[(AVAILABLE_FIELD, avail_off), (VANITY_FIELD, vanity_off)],
        );
        install_class_at(
            &mut mem,
            AddrPlan::PROVIDER_CLASS,
            AddrPlan::PROVIDER_VTABLE,
            provider_class_bytes,
        );
        let mut provider_payload = vec![0u8; 0x40];
        stamp_ptr(&mut provider_payload, 0, AddrPlan::PROVIDER_VTABLE);
        stamp_ptr(&mut provider_payload, avail_off, AddrPlan::AVAILABLE_OBJECT);
        stamp_ptr(&mut provider_payload, vanity_off, AddrPlan::VANITY_OBJECT);
        mem.add(AddrPlan::PROVIDER_OBJECT, provider_payload);

        // Five-field CosmeticsClient — Pets absent.
        let art_off = 0x10i32;
        let avatars_off = 0x18i32;
        let sleeves_off = 0x28i32;
        let emotes_off = 0x30i32;
        let titles_off = 0x38i32;
        let client_class_bytes = install_class_fields(
            &mut mem,
            AddrPlan::CLIENT_CLASS_FIELDS,
            &[
                (ART_STYLES_FIELD, art_off),
                (AVATARS_FIELD, avatars_off),
                // PETS_FIELD intentionally absent.
                (SLEEVES_FIELD, sleeves_off),
                (EMOTES_FIELD, emotes_off),
                (TITLES_FIELD, titles_off),
            ],
        );
        install_class_at(
            &mut mem,
            AddrPlan::CLIENT_CLASS,
            AddrPlan::CLIENT_VTABLE,
            client_class_bytes,
        );

        // List class.
        let list_class_bytes = install_class_fields(
            &mut mem,
            AddrPlan::LIST_CLASS_FIELDS,
            &[("_items", 0x10), ("_size", 0x18)],
        );
        install_class_at(
            &mut mem,
            AddrPlan::LIST_CLASS,
            AddrPlan::LIST_VTABLE,
            list_class_bytes,
        );

        // CosmeticsClient instance — populate the five present fields.
        let mut client_payload = vec![0u8; 0x80];
        stamp_ptr(&mut client_payload, 0, AddrPlan::CLIENT_VTABLE);
        for (offset, size, idx) in [
            (art_off, 100, 0usize),
            (avatars_off, 50, 1),
            (sleeves_off, 25, 3),
            (emotes_off, 10, 4),
            (titles_off, 5, 5),
        ] {
            let list_addr = AddrPlan::list_obj(ClientKind::Available, idx);
            stamp_ptr(&mut client_payload, offset, list_addr);
            let mut list_payload = vec![0u8; 0x30];
            stamp_ptr(&mut list_payload, 0, AddrPlan::LIST_VTABLE);
            stamp_i32(&mut list_payload, 0x18, size);
            mem.add(list_addr, list_payload);
        }
        mem.add(AddrPlan::AVAILABLE_OBJECT, client_payload);

        // Vanity (4-field, all NULL strings).
        let vanity_class_bytes = install_class_fields(
            &mut mem,
            AddrPlan::VANITY_CLASS_FIELDS,
            &[
                (AVATAR_SELECTION_FIELD, 0x10),
                (CARD_BACK_SELECTION_FIELD, 0x18),
                (PET_SELECTION_FIELD, 0x20),
                (TITLE_SELECTION_FIELD, 0x30),
            ],
        );
        install_class_at(
            &mut mem,
            AddrPlan::VANITY_CLASS,
            AddrPlan::VANITY_VTABLE,
            vanity_class_bytes,
        );
        let mut vanity_payload = vec![0u8; 0x80];
        stamp_ptr(&mut vanity_payload, 0, AddrPlan::VANITY_VTABLE);
        mem.add(AddrPlan::VANITY_OBJECT, vanity_payload);

        let summary = from_papa_singleton(
            &offsets,
            AddrPlan::PAPA_OBJECT,
            &papa_class_bytes,
            |a, l| mem.read(a, l),
        )
        .expect("chain should resolve");

        // Pets defaulted to 0.
        assert_eq!(summary.available.pets, 0);
        // Other available fields populated.
        assert_eq!(summary.available.art_styles, 100);
        assert_eq!(summary.available.avatars, 50);
        assert_eq!(summary.available.sleeves, 25);
        // Owned defaulted (no field on provider).
        assert_eq!(summary.owned, CosmeticCounts::default());
    }
}
