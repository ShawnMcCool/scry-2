//! Spike — saved-deck memory-residency probe (Part B, phase 1).
//!
//! Scaffolds the binary that will walk MTGA's live process memory to
//! locate the SavedDeckCollection (or equivalent) class and determine
//! whether the user's saved decks are resident in memory between
//! gameplay sessions.
//!
//! This is a throwaway research binary — it ships nothing and is never
//! referenced from production code. Run via:
//!
//!   cargo run --release --bin saved-deck-collection-spike [-- --pid=<n>]
//!
//! Task 2 adds candidate class discovery; Task 3 adds the residency walk.

use std::env;
use std::fs;
use std::process::ExitCode;

use scry2_collection_reader::platform::{list_maps, read_bytes};
#[allow(unused_imports)]
use scry2_collection_reader::walker::{
    class_lookup, domain, field, image_lookup, instance_field, list_t,
    mono::{self, MonoOffsets, MONO_CLASS_FIELD_SIZE},
    run::{read_mono_image, CLASS_DEF_BLOB_LEN},
    vtable,
};

const MTGA_COMM: &str = "MTGA.exe";
const READ_NAME_MAX: usize = 256;
const MAX_FIELDS_PER_CLASS: usize = 64;
#[allow(dead_code)]
const CLASS_PARENT_OFFSET: usize = 0x30;
#[allow(dead_code)]
const MAX_STRING_CHARS: usize = 128;

fn main() -> ExitCode {
    let pid = match resolve_pid() {
        Ok(p) => p,
        Err(msg) => {
            eprintln!("[spike] could not resolve MTGA pid: {msg}");
            return ExitCode::FAILURE;
        }
    };
    println!("[spike] MTGA pid = {pid}");

    let maps_owned = match list_maps(pid) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("[spike] list_maps failed: {e:?}");
            return ExitCode::FAILURE;
        }
    };

    let read_mem = |addr: u64, len: usize| -> Option<Vec<u8>> { read_bytes(pid, addr, len).ok() };

    let offsets = MonoOffsets::mtga_default();

    let (mono_base, mono_bytes) = match read_mono_image(&maps_owned, &read_mem) {
        Some(v) => v,
        None => {
            eprintln!("[spike] could not stitch mono-2.0-bdwgc.dll image");
            return ExitCode::FAILURE;
        }
    };
    println!(
        "[spike] mono image base=0x{:x} stitched_bytes={}",
        mono_base,
        mono_bytes.len()
    );

    let domain_addr = match domain::find_root_domain(&mono_bytes, mono_base, &read_mem) {
        Some(d) => d,
        None => {
            eprintln!("[spike] mono_get_root_domain → nullptr");
            return ExitCode::FAILURE;
        }
    };
    println!("[spike] root_domain = 0x{:x}", domain_addr);

    let images = match image_lookup::list_all_images(&offsets, domain_addr, &read_mem) {
        Some(imgs) => imgs,
        None => {
            eprintln!("[spike] could not enumerate images");
            return ExitCode::FAILURE;
        }
    };
    println!("[spike] enumerated {} Mono images", images.len());

    // Task 2: candidate discovery here
    // Task 3: residency walk here

    ExitCode::SUCCESS
}

// ─────────────────────────── helpers (copied verbatim from papa_managers_spike) ───

fn resolve_pid() -> Result<i32, String> {
    for arg in env::args().skip(1) {
        if let Some(rest) = arg.strip_prefix("--pid=") {
            return rest
                .parse::<i32>()
                .map_err(|e| format!("--pid= not a number: {e}"));
        }
    }
    auto_discover_pid()
}

fn auto_discover_pid() -> Result<i32, String> {
    let mut candidates = Vec::new();
    let entries = fs::read_dir("/proc").map_err(|e| format!("read /proc: {e}"))?;
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name_str) = name.to_str() else {
            continue;
        };
        let Ok(pid) = name_str.parse::<i32>() else {
            continue;
        };
        let comm = fs::read_to_string(format!("/proc/{}/comm", pid)).unwrap_or_default();
        if comm.trim() != MTGA_COMM {
            continue;
        }
        let maps_raw = match fs::read_to_string(format!("/proc/{}/maps", pid)) {
            Ok(s) => s,
            Err(_) => continue,
        };
        if !maps_raw.contains("mono-2.0-bdwgc.dll") {
            continue;
        }
        if !maps_raw.contains("UnityPlayer.dll") {
            continue;
        }
        let status = fs::read_to_string(format!("/proc/{}/status", pid)).unwrap_or_default();
        let vm_rss_kb: u64 = status
            .lines()
            .find(|l| l.starts_with("VmRSS:"))
            .and_then(|l| l.split_whitespace().nth(1))
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);
        if vm_rss_kb < 500_000 {
            continue;
        }
        candidates.push(pid);
    }
    match candidates.len() {
        0 => Err("no MTGA process found — is MTGA running?".to_string()),
        1 => Ok(candidates[0]),
        n => Err(format!("{} MTGA candidates; pass --pid=<n>", n)),
    }
}

#[allow(dead_code)]
fn find_class_in_any<F>(
    offsets: &MonoOffsets,
    images: &[u64],
    class_name: &str,
    read_mem: &F,
) -> Option<u64>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    for &img in images {
        if let Some(addr) =
            scry2_collection_reader::walker::class_lookup::find_class_by_name(
                offsets, img, class_name, read_mem,
            )
        {
            return Some(addr);
        }
    }
    None
}

#[allow(dead_code)]
fn drill_pointer_fields<F>(
    offsets: &MonoOffsets,
    obj_addr: u64,
    class_bytes: &[u8],
    read_mem: &F,
) where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let fields_ptr = mono::class_fields_ptr(offsets, class_bytes, 0).unwrap_or(0);
    let count = mono::class_def_field_count(offsets, class_bytes, 0).unwrap_or(0) as usize;
    let bounded = count.min(MAX_FIELDS_PER_CLASS);
    if fields_ptr == 0 || bounded == 0 {
        return;
    }
    for i in 0..bounded {
        let Some(off) = (i as u64).checked_mul(MONO_CLASS_FIELD_SIZE as u64) else {
            continue;
        };
        let Some(entry) = read_mem(fields_ptr + off, MONO_CLASS_FIELD_SIZE) else {
            continue;
        };
        let name_ptr = mono::field_name_ptr(offsets, &entry, 0).unwrap_or(0);
        let type_ptr = mono::field_type_ptr(offsets, &entry, 0).unwrap_or(0);
        let offset_val = mono::field_offset_value(offsets, &entry, 0).unwrap_or(0);
        let name = read_c_string(name_ptr, READ_NAME_MAX, read_mem).unwrap_or_default();
        if name.is_empty() {
            break;
        }
        if type_ptr == 0 {
            continue;
        }
        let Some(tb) = read_mem(type_ptr, 16) else {
            continue;
        };
        let attrs = mono::type_attrs(offsets, &tb, 0).unwrap_or(0);
        if mono::attrs_is_static(attrs) {
            continue;
        }
        if (offset_val as i32) < 0x10 {
            continue;
        }
        let Some(ptr_bytes) = read_mem(obj_addr + offset_val as u64, 8) else {
            continue;
        };
        let Some(target_addr) = read_u64(&ptr_bytes) else {
            continue;
        };
        if target_addr == 0 {
            println!(
                "    [{:2}] '{}' @ 0x{:04x} → NULL",
                i, name, offset_val as u32
            );
            continue;
        }
        let inner_class = match read_object_class(target_addr, read_mem) {
            Some(c) => c,
            None => {
                println!(
                    "    [{:2}] '{}' @ 0x{:04x} → 0x{:x} (no readable vtable)",
                    i, name, offset_val as u32, target_addr
                );
                continue;
            }
        };
        let inner_class_bytes = match read_mem(inner_class, CLASS_DEF_BLOB_LEN) {
            Some(b) => b,
            None => continue,
        };
        let inner_name = read_class_name(&inner_class_bytes, read_mem)
            .unwrap_or_else(|| "?".to_string());
        println!(
            "    [{:2}] '{}' @ 0x{:04x} → 0x{:x} class='{}'",
            i, name, offset_val as u32, target_addr, inner_name
        );
    }
}

fn read_u64(b: &[u8]) -> Option<u64> {
    if b.len() < 8 {
        None
    } else {
        Some(u64::from_le_bytes([
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
        ]))
    }
}

fn read_c_string<F>(addr: u64, max: usize, read_mem: &F) -> Option<String>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    if addr == 0 {
        return None;
    }
    let bytes = read_mem(addr, max)?;
    let nul = bytes.iter().position(|b| *b == 0).unwrap_or(bytes.len());
    String::from_utf8(bytes[..nul].to_vec()).ok()
}

fn read_object_class<F>(obj_addr: u64, read_mem: &F) -> Option<u64>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let vtable_addr = read_mem(obj_addr, 8).and_then(|b| read_u64(&b))?;
    if vtable_addr == 0 {
        return None;
    }
    let klass = read_mem(vtable_addr, 8).and_then(|b| read_u64(&b))?;
    if klass == 0 {
        return None;
    }
    Some(klass)
}

#[allow(dead_code)]
fn read_class_name<F>(class_bytes: &[u8], read_mem: &F) -> Option<String>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    if class_bytes.len() < 0x50 {
        return None;
    }
    let name_ptr = u64::from_le_bytes([
        class_bytes[0x48],
        class_bytes[0x49],
        class_bytes[0x4a],
        class_bytes[0x4b],
        class_bytes[0x4c],
        class_bytes[0x4d],
        class_bytes[0x4e],
        class_bytes[0x4f],
    ]);
    read_c_string(name_ptr, READ_NAME_MAX, read_mem)
}

#[allow(dead_code)]
fn dump_class_own_fields<F>(offsets: &MonoOffsets, class_bytes: &[u8], read_mem: &F)
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let fields_ptr = mono::class_fields_ptr(offsets, class_bytes, 0).unwrap_or(0);
    let count = mono::class_def_field_count(offsets, class_bytes, 0).unwrap_or(0) as usize;
    let bounded = count.min(MAX_FIELDS_PER_CLASS);
    if fields_ptr == 0 || bounded == 0 {
        return;
    }
    for i in 0..bounded {
        let entry_addr = match (i as u64).checked_mul(MONO_CLASS_FIELD_SIZE as u64) {
            Some(off) => fields_ptr + off,
            None => continue,
        };
        let entry_bytes = match read_mem(entry_addr, MONO_CLASS_FIELD_SIZE) {
            Some(b) => b,
            None => continue,
        };
        let name_ptr = mono::field_name_ptr(offsets, &entry_bytes, 0).unwrap_or(0);
        let type_ptr = mono::field_type_ptr(offsets, &entry_bytes, 0).unwrap_or(0);
        let offset_val = mono::field_offset_value(offsets, &entry_bytes, 0).unwrap_or(0);
        let name = read_c_string(name_ptr, READ_NAME_MAX, read_mem).unwrap_or_default();
        if name.is_empty() {
            break;
        }
        let (attrs, is_static) = if type_ptr != 0 {
            match read_mem(type_ptr, 16) {
                Some(tb) => {
                    let a = mono::type_attrs(offsets, &tb, 0).unwrap_or(0);
                    (a, mono::attrs_is_static(a))
                }
                None => (0, false),
            }
        } else {
            (0, false)
        };
        println!(
            "      [{:2}] offset=0x{:04x} {} attrs=0x{:04x} name='{}'",
            i,
            offset_val as u32,
            if is_static { "STATIC  " } else { "instance" },
            attrs,
            name,
        );
    }
}
