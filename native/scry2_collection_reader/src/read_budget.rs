//! Per-invocation read-count budget for walker NIFs.
//!
//! The walker chases pointer chains in remote process memory. When the
//! target process is alive and well-formed every walk terminates after
//! a bounded number of reads. When the input is degenerate — typically
//! because MTGA quit mid-match and the cached pid was reused by an
//! unrelated process, or because a self-referential pointer-chain loop
//! is hit on partially-zeroed memory — the walker can spin
//! indefinitely on a dirty-IO scheduler thread, pegging a CPU core
//! and blocking the caller GenServer (which can't even process its
//! own safety timer because the synchronous NIF call never returns).
//!
//! [`bounded`] wraps any `Fn(u64, usize) -> Option<Vec<u8>>` reader
//! with an atomic read counter and a hard ceiling. After the
//! ceiling is reached every subsequent read returns `None` — the same
//! signal the walker already treats as a terminal read failure — so
//! the walk unwinds with `Err(WalkError::*)` and the NIF returns to
//! Elixir within bounded time.
//!
//! The counter lives in the caller's stack frame so each NIF
//! invocation gets a fresh budget; concurrent invocations don't share
//! state. `Ordering::Relaxed` is sufficient — every NIF is dispatched
//! to one dirty-IO scheduler thread and the closure is called from
//! that thread only.

use std::sync::atomic::{AtomicU64, Ordering};

/// Read budget for one [`crate::walker::run::walk_match_info`] or
/// [`crate::walker::run::walk_collection`] invocation.
///
/// A walk against current MTGA (build `Fri Apr 11 17:22:20 2025`)
/// scans 222 loaded Mono images while resolving `PAPA`,
/// `MatchSceneManager`, and friends — class lookup against an image
/// walks the class hash buckets, which dominates the read count.
/// The previous 5,000 ceiling (sized for the early walker against a
/// smaller image set) was being silently exceeded — every read past
/// the cap returns `None`, the walker bails with `ClassNotFound`, and
/// Chain-1 / Chain-2 silently produce nothing. v0.30.3 raised the
/// ceiling to 200,000 after this regression was diagnosed; the
/// `walker_debug_walk_match_info_with_stats` NIF now reports actual
/// reads_used per call so further drift is visible before it breaks.
///
/// 200k caps any single walk at ~0.2 s of `process_vm_readv` time on
/// commodity hardware, well under the 500 ms LiveState poll interval,
/// while leaving an order-of-magnitude margin over the current
/// measured cost. **Watch this knob.** If MTGA grows further and the
/// stats start reporting reads_used close to budget, raise it again
/// — or better, finish the v0.31.0 discovery-cache work that drops
/// the steady-state cost to a few hundred reads per tick.
pub const WALK_READ_BUDGET: u64 = 200_000;

/// Wrap `inner` with an atomic read counter capped at `budget`.
///
/// The returned closure is `Fn + Copy` so it satisfies the walker's
/// signature requirements; the counter is borrowed from `counter` so
/// the closure stays cheap to copy. Ownership of the counter stays
/// with the caller — typically a stack-local in the NIF wrapper —
/// which means the budget is per-invocation and not shared across
/// concurrent NIF calls.
pub fn bounded<'a, F>(
    counter: &'a AtomicU64,
    budget: u64,
    inner: F,
) -> impl Fn(u64, usize) -> Option<Vec<u8>> + Copy + 'a
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy + 'a,
{
    move |addr, len| {
        if counter.fetch_add(1, Ordering::Relaxed) >= budget {
            return None;
        }
        inner(addr, len)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn under_budget_passes_reads_through() {
        let counter = AtomicU64::new(0);
        let inner = |_addr: u64, _len: usize| Some(vec![0xaa_u8; 4]);
        let bounded_reader = bounded(&counter, 3, inner);

        assert_eq!(bounded_reader(0, 4), Some(vec![0xaa_u8; 4]));
        assert_eq!(bounded_reader(0, 4), Some(vec![0xaa_u8; 4]));
        assert_eq!(bounded_reader(0, 4), Some(vec![0xaa_u8; 4]));
    }

    #[test]
    fn at_budget_returns_none_for_subsequent_reads() {
        let counter = AtomicU64::new(0);
        let inner = |_addr: u64, _len: usize| Some(vec![0u8; 4]);
        let bounded_reader = bounded(&counter, 3, inner);

        for _ in 0..3 {
            let _ = bounded_reader(0, 4);
        }

        assert_eq!(
            bounded_reader(0, 4),
            None,
            "4th read with budget=3 must short-circuit"
        );
        assert_eq!(
            bounded_reader(0, 4),
            None,
            "5th read with budget=3 must short-circuit"
        );
    }

    #[test]
    fn budget_is_per_counter_not_global() {
        // Two parallel NIF calls each get their own counter; one
        // exhausting its budget must not affect the other.
        let counter_a = AtomicU64::new(0);
        let counter_b = AtomicU64::new(0);
        let inner = |_addr: u64, _len: usize| Some(vec![0u8; 4]);
        let reader_a = bounded(&counter_a, 1, inner);
        let reader_b = bounded(&counter_b, 5, inner);

        assert_eq!(reader_a(0, 4), Some(vec![0u8; 4]));
        assert_eq!(reader_a(0, 4), None);

        // counter_b is untouched by counter_a's exhaustion.
        for _ in 0..5 {
            assert_eq!(reader_b(0, 4), Some(vec![0u8; 4]));
        }
        assert_eq!(reader_b(0, 4), None);
    }

    #[test]
    fn counter_records_total_attempted_reads() {
        let counter = AtomicU64::new(0);
        let inner = |_addr: u64, _len: usize| Some(vec![0u8; 4]);
        let bounded_reader = bounded(&counter, 2, inner);

        for _ in 0..7 {
            let _ = bounded_reader(0, 4);
        }

        // Counter records every attempt, even those past the budget,
        // so post-walk inspection (logs, telemetry) can detect when a
        // walk hit the ceiling vs. terminated naturally.
        assert_eq!(counter.load(Ordering::Relaxed), 7);
    }

    #[test]
    fn returned_closure_is_copy_so_walker_signature_is_satisfied() {
        // Walker entry points (e.g. walker::run::walk_match_info) bound
        // the reader closure as `Fn(u64, usize) -> Option<Vec<u8>> + Copy`.
        // This compile-time assertion proves the bounded wrapper still
        // satisfies that bound.
        fn assert_copy_fn<F: Fn(u64, usize) -> Option<Vec<u8>> + Copy>(_: F) {}

        let counter = AtomicU64::new(0);
        let inner = |_addr: u64, _len: usize| Some(vec![0u8; 4]);
        assert_copy_fn(bounded(&counter, 10, inner));
    }
}
