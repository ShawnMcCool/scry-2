//! Centralized read caps for the walker.
//!
//! Three identical `MAX_NAME_LEN = 256` constants used to live in
//! `class_lookup`, `image_lookup`, and `field` (audit findings 1.4 +
//! 6.5); the per-collection caps were also scattered across half a
//! dozen files (finding 1.5). This module is the single source of
//! truth — every other walker module imports from here.
//!
//! ## What each cap protects against
//!
//! Walker reads chase pointers through arbitrary remote memory in
//! a process we don't control. A torn read on a `_size`, `max_length`,
//! or `count` field can yield a multi-GB allocation request. Every
//! cap below answers two questions:
//!
//! 1. What's the largest plausible real value? (e.g. MTGA collection
//!    is ~5K cards; commander decks have 1–2 commanders.)
//! 2. What headroom keeps the cap useful for years without crossing
//!    into "this many bytes would crash the BEAM"?
//!
//! Tests intentionally trip these caps to exercise the rejection
//! paths — when bumping a cap, also bump the corresponding negative
//! test fixture.

/// Longest C# field, class, or assembly name the walker will compare.
/// MTGA's longest names hover around 60 characters (auto-property
/// backing-field forms). 256 bytes is comfortable headroom without
/// pulling megabytes for every candidate.
///
/// Used by `field::find_field_by_name`, `class_lookup::find_class_by_name`, and
/// `image_lookup::find_image_by_name`.
pub const MAX_NAME_LEN: usize = 256;

/// Cap on entries returned from a single `Dictionary<int, int>` read.
/// Sized for MTGA's collection (~5K cards today, headroom for years)
/// with a hard cap that bounds allocation cost on a corrupt
/// `max_length`.
pub const MAX_DICT_INT_INT_ENTRIES: u64 = 100_000;

/// Cap on entries from a single `Dictionary<int, ptr>` read.
/// Match-state dictionaries (`PlayerTypeMap`, zone maps) are tiny —
/// 1024 is plenty above any real value.
pub const MAX_DICT_INT_PTR_ENTRIES: u64 = 1024;

/// Cap on element count read from any `List<T>`. Real lists in MTGA
/// are well under this (deck size ≤ 250, layout data ≤ ~150). Bounds
/// torn-read damage if `_size` is garbage.
pub const MAX_LIST_ELEMENTS: usize = 1024;

/// Cap on Mono assemblies the walker will iterate when looking up an
/// image by name. MTGA loads ~50 assemblies; 1024 is multi-decade
/// headroom.
pub const MAX_ASSEMBLIES: usize = 1024;

/// Cap on total class iterations across the Mono class hash table.
/// Used by `class_lookup` as a global ceiling so a chain cycle in the
/// `next_class_cache` linked list cannot stall the walker.
pub const MAX_TOTAL_CLASSES: usize = 65_536;

/// Cap on hash-table bucket count when iterating a Mono class hash.
/// Defends against absurd `MonoClassMetadataHash.size` values.
pub const MAX_BUCKETS: usize = 1_048_576;

/// Cap on Mono runtime-info domains when locating a class's per-domain
/// vtable. The Unity build runs a single domain; 64 is overkill but
/// guards against a torn `max_domain` short field.
pub const MAX_DOMAINS: u16 = 64;

/// Cap on `MonoString` length (in UTF-16 code units) for the standard
/// "screen name / match id"-style read. MTGA screen names are ≤ 26
/// chars; 1024 is generous and bounds torn-read damage.
pub const MAX_STRING_CHARS: usize = 1024;

/// Cap on `CommanderGrpIds` lists (Brawl/Commander). Real values are
/// 1–2; 32 is far above any conceivable game state.
pub const MAX_COMMANDER_LIST: usize = 32;
