//! Mono walker — navigates MTGA's in-process Mono runtime to produce
//! a decoded collection snapshot.
//!
//! The walker is the primary path for `Scry2.Collection.Reader`; the
//! Elixir-side `Scanner` is kept as a fallback.
//!
//! ## Pointer chain
//!
//! Starting from the exported symbol `mono_get_root_domain` in
//! `mono-2.0-bdwgc.dll`, the walker follows:
//!
//! ```text
//!   mono_get_root_domain()               -> MonoDomain *
//!     PAPA (class in Core.dll)
//!       <Instance>k__BackingField        -> PAPA singleton
//!         <InventoryManager>k__BackingField -> IInventoryManager
//!           _inventoryServiceWrapper     -> InventoryServiceWrapper
//!             <Cards>k__BackingField     -> Dictionary<int,int>
//!             m_inventory                -> ClientPlayerInventory
//!                                           (wildcards, gold, gems,
//!                                            vault progress)
//! ```
//!
//! See `decisions/architecture/2026-04-22-034-memory-read-collection.md`
//! (Revision 2026-04-25) and the `mtga-duress` research repo,
//! specifically `experiments/spikes/spike5_mono_metadata/` and
//! `experiments/spikes/spike7_papa_walk/`.

// Individual pieces land test-first; each module is unused until the
// layer above consumes it. Once `walk_collection` is wired, this allow
// comes off.
#![allow(dead_code)]

pub mod prologue;
