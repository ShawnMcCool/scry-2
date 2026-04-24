//! scry2_collection_reader — memory-reader NIF crate (ADR 034).
//!
//! Exposes three primitives used by `Scry2.Collection.Reader`:
//!   * `read_bytes(pid, addr, size)`       — read remote process memory
//!   * `list_maps(pid)`                    — enumerate mapped regions
//!   * `list_processes()`                  — enumerate running processes
//!
//! Plus `ping/0` as an NIF-load heartbeat.
//!
//! Platform impls live in `linux.rs` / `windows.rs` / `macos.rs`;
//! only Linux is implemented today, the others return `:not_implemented`.
//!
//! Every NIF runs on the `DirtyIo` scheduler — all three primitives
//! hit the filesystem or syscalls and would otherwise starve the
//! regular schedulers.

#![deny(clippy::panic, clippy::unwrap_used, clippy::expect_used)]

use rustler::{Atom, Binary, Env, OwnedBinary};

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

rustler::init!("Elixir.Scry2.Collection.Mem.Nif");
