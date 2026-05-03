//! Per-pid cache of expensive discovery results.
//!
//! Both walker chains begin by scanning every loaded Mono image to
//! resolve a single anchor class (`PAPA` for Chain-1, `MatchSceneManager`
//! for Chain-2, plus `Dictionary\`2` for Chain-Collection). On the
//! current MTGA build that scan dominates the per-call cost — measured
//! at ~64–69k `process_vm_readv` calls per walk against 222 images.
//! The chain traversal *after* the anchor is reached is cheap (a few
//! hundred reads).
//!
//! These anchors don't move while MTGA is running. Caching them keyed
//! by pid lets every walk after the first skip the scan entirely:
//! steady-state cost drops two orders of magnitude. The cache is
//! invalidated naturally — when MTGA restarts the pid changes and
//! the next call misses, re-discovers, and re-populates.
//!
//! Stale-entry detection: if a chain that uses cached values fails
//! at the cached step, the caller is expected to call
//! [`invalidate`] for that pid and retry. The cost of one wrong walk
//! is one `find_class_in_images` for the next one — strictly bounded.
//!
//! Concurrency: a single `Mutex<HashMap>` guards the whole table.
//! NIFs run on dirty-IO scheduler threads with potentially concurrent
//! invocations against different pids; the lock is held only for the
//! lookup/insert (not the underlying memory reads), so contention is
//! negligible.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

use crate::walker::mono::MonoOffsets;
use crate::walker::{domain, image_lookup, run::read_mono_image};

/// Anchor class metadata cached for one chain. The class address +
/// pre-read class def bytes are enough for the chain code to do the
/// rest of its work without re-scanning images.
#[derive(Clone)]
pub struct ChainAnchor {
    pub class_addr: u64,
    pub class_bytes: Vec<u8>,
}

/// Bytes of the mono DLL plus its load address. The walker uses
/// these to derive `mono_root_domain` via the `mono_get_root_domain`
/// prologue parse — also cached so we only do the parse once per
/// pid.
#[derive(Clone)]
pub struct MonoImage {
    pub base: u64,
    pub bytes: Vec<u8>,
}

/// Everything we cache for one MTGA process. Each `Option` is filled
/// the first time the corresponding chain is asked for; subsequent
/// calls hit the cache.
#[derive(Clone, Default)]
pub struct PidCache {
    pub mono_image: Option<MonoImage>,
    pub root_domain: Option<u64>,
    pub all_images: Option<Vec<u64>>,
    pub papa: Option<ChainAnchor>,
    pub scene: Option<ChainAnchor>,
    pub dict_generic: Option<ChainAnchor>,
}

static CACHE: OnceLock<Mutex<HashMap<u32, PidCache>>> = OnceLock::new();

fn cache() -> &'static Mutex<HashMap<u32, PidCache>> {
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Drop the cache for `pid`. Call this when a chain that relied on
/// cached values failed at a cached step — typically a stale class
/// pointer after MTGA hot-reloads its scripting domain (rare but
/// possible).
pub fn invalidate(pid: u32) {
    if let Ok(mut map) = cache().lock() {
        map.remove(&pid);
    }
}

/// Drop the entire cache. For tests and admin "Clear cache" actions.
pub fn clear_all() {
    if let Ok(mut map) = cache().lock() {
        map.clear();
    }
}

/// Snapshot the cache state (for diagnostics). Returns `(pid,
/// chain_summaries)` tuples — `chain_summaries` is a comma-separated
/// list of which anchors are currently cached.
pub fn snapshot() -> Vec<(u32, String)> {
    let Ok(map) = cache().lock() else {
        return Vec::new();
    };
    let mut out: Vec<_> = map
        .iter()
        .map(|(pid, entry)| {
            let mut parts = Vec::new();
            if entry.mono_image.is_some() {
                parts.push("mono");
            }
            if entry.root_domain.is_some() {
                parts.push("domain");
            }
            if entry.all_images.is_some() {
                parts.push("images");
            }
            if entry.papa.is_some() {
                parts.push("PAPA");
            }
            if entry.scene.is_some() {
                parts.push("MatchSceneManager");
            }
            if entry.dict_generic.is_some() {
                parts.push("Dictionary`2");
            }
            (*pid, parts.join(","))
        })
        .collect();
    out.sort_by_key(|(pid, _)| *pid);
    out
}

/// Get-or-resolve the mono image bytes for `pid`. Cheap on cache hit.
/// Returns `None` if `mono-2.0-bdwgc.dll` isn't mapped (i.e. not an
/// MTGA process or process gone).
pub fn get_mono_image<F>(
    pid: u32,
    maps: &[crate::MapEntry],
    read_mem: F,
) -> Option<MonoImage>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    if let Some(entry) = read_entry(pid) {
        if let Some(image) = entry.mono_image {
            return Some(image);
        }
    }
    let (base, bytes) = read_mono_image(maps, &read_mem)?;
    if bytes.is_empty() {
        return None;
    }
    let image = MonoImage { base, bytes };
    update_entry(pid, |e| e.mono_image = Some(image.clone()));
    Some(image)
}

/// Get-or-resolve the root domain pointer.
pub fn get_root_domain<F>(pid: u32, mono_image: &MonoImage, read_mem: F) -> Option<u64>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    if let Some(entry) = read_entry(pid) {
        if let Some(addr) = entry.root_domain {
            return Some(addr);
        }
    }
    let addr = domain::find_root_domain(&mono_image.bytes, mono_image.base, read_mem)?;
    update_entry(pid, |e| e.root_domain = Some(addr));
    Some(addr)
}

/// Get-or-resolve the loaded image addresses.
pub fn get_all_images<F>(
    pid: u32,
    offsets: &MonoOffsets,
    domain_addr: u64,
    read_mem: F,
) -> Option<Vec<u64>>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    if let Some(entry) = read_entry(pid) {
        if let Some(images) = entry.all_images {
            return Some(images);
        }
    }
    let images = image_lookup::list_all_images(offsets, domain_addr, read_mem)?;
    if images.is_empty() {
        return None;
    }
    update_entry(pid, |e| e.all_images = Some(images.clone()));
    Some(images)
}

/// Get-or-resolve a named anchor class. The first lookup pays the
/// 222-image scan; every subsequent call returns the cached
/// `(class_addr, class_bytes)` directly.
pub fn get_anchor<F>(
    pid: u32,
    anchor_kind: AnchorKind,
    offsets: &MonoOffsets,
    images: &[u64],
    name: &str,
    class_def_blob_len: usize,
    read_mem: F,
) -> Option<ChainAnchor>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    if let Some(entry) = read_entry(pid) {
        if let Some(anchor) = anchor_kind.get(&entry) {
            return Some(anchor.clone());
        }
    }
    let class_addr = images.iter().find_map(|img| {
        crate::walker::class_lookup::find_class_by_name(offsets, *img, name, read_mem)
    })?;
    let class_bytes = read_mem(class_addr, class_def_blob_len)?;
    let anchor = ChainAnchor {
        class_addr,
        class_bytes,
    };
    let cloned = anchor.clone();
    update_entry(pid, |e| anchor_kind.set(e, cloned.clone()));
    Some(anchor)
}

/// Selector for which anchor slot in [`PidCache`] a [`get_anchor`]
/// call targets. Avoids stringly-typed dispatch.
#[derive(Clone, Copy, Debug)]
pub enum AnchorKind {
    Papa,
    Scene,
    DictGeneric,
}

impl AnchorKind {
    fn get<'a>(&self, entry: &'a PidCache) -> Option<&'a ChainAnchor> {
        match self {
            AnchorKind::Papa => entry.papa.as_ref(),
            AnchorKind::Scene => entry.scene.as_ref(),
            AnchorKind::DictGeneric => entry.dict_generic.as_ref(),
        }
    }

    fn set(&self, entry: &mut PidCache, anchor: ChainAnchor) {
        match self {
            AnchorKind::Papa => entry.papa = Some(anchor),
            AnchorKind::Scene => entry.scene = Some(anchor),
            AnchorKind::DictGeneric => entry.dict_generic = Some(anchor),
        }
    }
}

fn read_entry(pid: u32) -> Option<PidCache> {
    cache().lock().ok()?.get(&pid).cloned()
}

fn update_entry(pid: u32, edit: impl FnOnce(&mut PidCache)) {
    if let Ok(mut map) = cache().lock() {
        let entry = map.entry(pid).or_default();
        edit(entry);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn invalidate_drops_only_the_named_pid() {
        clear_all();
        update_entry(1, |e| e.root_domain = Some(0xdead));
        update_entry(2, |e| e.root_domain = Some(0xbeef));
        invalidate(1);
        assert!(read_entry(1).is_none());
        assert_eq!(read_entry(2).unwrap().root_domain, Some(0xbeef));
        clear_all();
    }

    #[test]
    fn snapshot_lists_filled_slots() {
        clear_all();
        update_entry(42, |e| {
            e.mono_image = Some(MonoImage {
                base: 0x1000,
                bytes: vec![0u8; 16],
            });
            e.root_domain = Some(0x2000);
            e.papa = Some(ChainAnchor {
                class_addr: 0x3000,
                class_bytes: vec![0u8; 8],
            });
        });

        let snap = snapshot();
        assert_eq!(snap.len(), 1);
        let (pid, summary) = &snap[0];
        assert_eq!(*pid, 42);
        assert!(summary.contains("mono"));
        assert!(summary.contains("domain"));
        assert!(summary.contains("PAPA"));
        assert!(!summary.contains("MatchSceneManager"));
        clear_all();
    }
}
