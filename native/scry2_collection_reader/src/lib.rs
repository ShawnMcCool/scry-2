//! scry2_collection_reader — native memory-reader NIF for ADR 034.
//!
//! Phase 1 only exposes `ping/0` to prove the build and load path. The
//! read/list/find primitives land in Phase 4.

mod atoms {
    rustler::atoms! {
        pong,
    }
}

#[rustler::nif]
fn ping() -> rustler::Atom {
    atoms::pong()
}

rustler::init!("Elixir.Scry2.Collection.Mem.Nif");
