//! scry2_collection_reader — memory-reader NIF crate (ADR 034).
//!
//! Exposes four NIFs used by `Scry2.Collection.Reader`:
//!   * `read_bytes(pid, addr, size)`       — read remote process memory
//!   * `list_maps(pid)`                    — enumerate mapped regions
//!   * `list_processes()`                  — enumerate running processes
//!   * `walk_collection(pid)`              — run the whole walker pipeline
//!
//! Plus `ping/0` as an NIF-load heartbeat.
//!
//! Platform impls live in `linux.rs` / `windows.rs` / `macos.rs`;
//! only Linux is implemented today, the others return `:not_implemented`.
//!
//! Every NIF runs on the `DirtyIo` scheduler — all primitives hit the
//! filesystem or syscalls and would otherwise starve the regular
//! schedulers.

#![deny(clippy::panic, clippy::unwrap_used, clippy::expect_used)]

use rustler::{Atom, Binary, Env, NifMap, NifTaggedEnum, NifTuple, OwnedBinary};

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
use linux as platform;

mod walker;

#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "macos")]
use macos as platform;

#[cfg(target_os = "windows")]
mod windows;
#[cfg(target_os = "windows")]
use windows as platform;

mod atoms {
    rustler::atoms! {
        pong,
        unmapped,
        no_process,
        permission_denied,
        io_error,
        not_implemented,
    }
}

/// Platform-level failure modes; mapped into atoms at the NIF boundary.
#[derive(Debug)]
pub enum PlatformError {
    Unmapped,
    NoProcess,
    PermissionDenied,
    IoError,
    NotImplemented,
}

fn err_atom(e: PlatformError) -> Atom {
    match e {
        PlatformError::Unmapped => atoms::unmapped(),
        PlatformError::NoProcess => atoms::no_process(),
        PlatformError::PermissionDenied => atoms::permission_denied(),
        PlatformError::IoError => atoms::io_error(),
        PlatformError::NotImplemented => atoms::not_implemented(),
    }
}

#[rustler::nif]
fn ping() -> Atom {
    atoms::pong()
}

#[rustler::nif(schedule = "DirtyIo")]
fn read_bytes<'a>(env: Env<'a>, pid: i32, addr: u64, size: u64) -> Result<Binary<'a>, Atom> {
    match platform::read_bytes(pid, addr, size as usize) {
        Ok(buf) => match OwnedBinary::new(buf.len()) {
            Some(mut owned) => {
                owned.as_mut_slice().copy_from_slice(&buf);
                Ok(Binary::from_owned(owned, env))
            }
            None => Err(atoms::io_error()),
        },
        Err(e) => Err(err_atom(e)),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn list_maps_nif(pid: i32) -> Result<Vec<(u64, u64, String, Option<String>)>, Atom> {
    platform::list_maps(pid).map_err(err_atom)
}

#[rustler::nif(schedule = "DirtyIo")]
fn list_processes_nif() -> Result<Vec<(u32, String, String)>, Atom> {
    platform::list_processes().map_err(err_atom)
}

// ============================================================
// walk_collection NIF — exposes the Rust walker as a single
// fourth NIF (ADR-034 Revision 2026-04-25).
// ============================================================

/// One row in the `cards` list — `{arena_id, count}` 2-tuple on the
/// Elixir side.
#[derive(NifTuple)]
pub struct CardEntry {
    pub arena_id: i32,
    pub count: i32,
}

/// `wildcards: %{common, uncommon, rare, mythic}` map.
#[derive(NifMap)]
pub struct Wildcards {
    pub common: i32,
    pub uncommon: i32,
    pub rare: i32,
    pub mythic: i32,
}

/// Wire shape returned to Elixir on success — matches the contract
/// in `decisions/architecture/2026-04-22-034-memory-read-collection.md`
/// (Revision 2026-04-25).
#[derive(NifMap)]
pub struct WalkSnapshot {
    pub cards: Vec<CardEntry>,
    pub wildcards: Wildcards,
    pub gold: i32,
    pub gems: i32,
    pub vault_progress: i32,
    pub build_hint: Option<String>,
    pub reader_version: String,
}

/// Wire-format mirror of [`walker::run::WalkError`]. Variants
/// carrying a class- or assembly-name parameter become tagged
/// tuples on the Elixir side, e.g.
/// `{:assembly_not_found, "Core"}`. Unit variants become bare atoms.
#[derive(NifTaggedEnum)]
pub enum WalkErrorWire {
    MonoDllNotFound,
    MonoDllReadFailed,
    RootDomainNotFound,
    AssemblyNotFound(String),
    ClassNotFound(String),
    ClassReadFailed(String),
    ChainFailed,
}

impl From<walker::run::WalkError> for WalkErrorWire {
    fn from(e: walker::run::WalkError) -> Self {
        use walker::run::WalkError as E;
        match e {
            E::MonoDllNotFound => Self::MonoDllNotFound,
            E::MonoDllReadFailed => Self::MonoDllReadFailed,
            E::RootDomainNotFound => Self::RootDomainNotFound,
            E::AssemblyNotFound(name) => Self::AssemblyNotFound(name.to_string()),
            E::ClassNotFound(name) => Self::ClassNotFound(name.to_string()),
            E::ClassReadFailed(name) => Self::ClassReadFailed(name.to_string()),
            E::ChainFailed => Self::ChainFailed,
        }
    }
}

/// Static identifier of the walker build, surfaced as `reader_version`
/// in [`WalkSnapshot`]. Bumped manually when the chain or offset
/// table changes in a way that would invalidate cached snapshots.
const READER_VERSION: &str = concat!("scry2-walker-", env!("CARGO_PKG_VERSION"));

fn snapshot_to_wire(snap: walker::run::Snapshot) -> WalkSnapshot {
    WalkSnapshot {
        cards: snap
            .entries
            .into_iter()
            .map(|e| CardEntry {
                arena_id: e.key,
                count: e.value,
            })
            .collect(),
        wildcards: Wildcards {
            common: snap.inventory.wc_common,
            uncommon: snap.inventory.wc_uncommon,
            rare: snap.inventory.wc_rare,
            mythic: snap.inventory.wc_mythic,
        },
        gold: snap.inventory.gold,
        gems: snap.inventory.gems,
        vault_progress: snap.inventory.vault_progress,
        build_hint: snap.mtga_build_hint,
        reader_version: READER_VERSION.to_string(),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn walk_collection(pid: i32) -> Result<WalkSnapshot, WalkErrorWire> {
    let maps = platform::list_maps(pid).map_err(|_| WalkErrorWire::MonoDllReadFailed)?;
    let read_mem = |addr: u64, len: usize| platform::read_bytes(pid, addr, len).ok();
    let snap = walker::run::walk_collection(&maps, read_mem, || {
        walker::build_hint::find_mtga_root(&maps)
            .and_then(|root| walker::build_hint::read_build_guid(&root))
    })
    .map_err(WalkErrorWire::from)?;
    Ok(snapshot_to_wire(snap))
}

rustler::init!("Elixir.Scry2.Collection.Mem.Nif");
