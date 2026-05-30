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
use scry2_collection_reader::walker::{
    class_lookup, domain, field, image_lookup, instance_field, list_t,
    mono::{self, MonoOffsets, MONO_CLASS_FIELD_SIZE},
    object,
    run::{read_mono_image, CLASS_DEF_BLOB_LEN},
    vtable,
};

/// Class-name substrings that plausibly name a saved-deck collection holder.
const DECK_CLASS_HINTS: &[&str] = &[
    "DeckManager",
    "DeckListManager",
    "DeckCollection",
    "DeckService",
    "DeckRepository",
    "DeckStore",
    "DeckList",
    "Deck", // broad net: print ALL classes containing "Deck" so nothing is missed
];

const MTGA_COMM: &str = "MTGA.exe";
const READ_NAME_MAX: usize = 256;
const MAX_FIELDS_PER_CLASS: usize = 64;
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
    scan_deck_candidates(&offsets, &images, read_mem);
    drill_papa_pointer_fields(&offsets, &images, domain_addr, read_mem);

    // Drill an arbitrary object instance (e.g. a manager found in the PAPA drill)
    // to inspect its pointer fields. DRILL_ADDR=0x.. enables it.
    if let Ok(drill_hex) = env::var("DRILL_ADDR") {
        let trimmed = drill_hex.trim().trim_start_matches("0x");
        match u64::from_str_radix(trimmed, 16) {
            Ok(addr) => drill_object(&offsets, addr, read_mem),
            Err(_) => eprintln!("[spike] DRILL_ADDR must be hex, e.g. 0x6fd38690"),
        }
    }

    // Task 3: residency walk here
    // The owning anchor + list field are discovered from Task 2 output; pass them
    // at runtime so re-runs don't require recompiling.
    match (env::var("DECK_OWNER_ADDR"), env::var("DECK_LIST_FIELD")) {
        (Ok(owner_hex), Ok(field_name)) => {
            let trimmed = owner_hex.trim().trim_start_matches("0x");
            match u64::from_str_radix(trimmed, 16) {
                Ok(owner_addr) => report_deck_residency(&offsets, owner_addr, &field_name, read_mem),
                Err(_) => eprintln!("[spike] DECK_OWNER_ADDR must be hex, e.g. 0x7f1234abcd00"),
            }
        }
        _ => {
            println!("\n[spike] set DECK_OWNER_ADDR=0x.. and DECK_LIST_FIELD=<name> to run the residency walk");
        }
    }

    ExitCode::SUCCESS
}

// ─────────────────────────── task-3 functions ─────────────────────────────────────

/// Given the address of the object that owns the saved-deck list and the name
/// of the field holding that `List<Deck>`, walk every Deck and report whether
/// its MainDeck is populated (the residency verdict driver).
fn report_deck_residency<F>(offsets: &MonoOffsets, owner_addr: u64, list_field_name: &str, read_mem: F)
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    println!("\n=== saved-deck residency report ===");
    println!("[spike] owner = {owner_addr:#x}, list field = {list_field_name:?}");

    let Some(owner_class) = object::read_runtime_class_bytes(owner_addr, &read_mem) else {
        println!("[spike] could not read owner runtime class");
        return;
    };
    let Some(list_addr) =
        object::read_instance_pointer_in_chain(offsets, &owner_class, owner_addr, list_field_name, &read_mem)
    else {
        println!("[spike] field {list_field_name:?} not found on owner (or null)");
        return;
    };
    if list_addr == 0 {
        println!("[spike] {list_field_name} is null — collection not resident");
        return;
    }

    let Some(list_class) = object::read_runtime_class_bytes(list_addr, &read_mem) else {
        println!("[spike] could not read list runtime class");
        return;
    };
    let size = list_t::read_size(offsets, &list_class, list_addr, &read_mem).unwrap_or(0);
    let deck_ptrs = list_t::read_pointer_list(offsets, &list_class, list_addr, &read_mem);
    println!("[spike] deck collection _size = {size}, pointers read = {}", deck_ptrs.len());

    let mut resident = 0usize;
    for (index, &deck_addr) in deck_ptrs.iter().enumerate() {
        if deck_addr == 0 {
            continue;
        }
        let Some(deck_class) = object::read_runtime_class_bytes(deck_addr, &read_mem) else {
            println!("  [{index}] <unreadable deck object @ {deck_addr:#x}>");
            continue;
        };
        let name = instance_field::read_instance_string(offsets, &deck_class, deck_addr, "Name", MAX_STRING_CHARS, &read_mem)
            .or_else(|| instance_field::read_instance_string(offsets, &deck_class, deck_addr, "name", MAX_STRING_CHARS, &read_mem))
            .unwrap_or_else(|| "<no name>".to_string());

        let main_deck_size = object::read_instance_pointer_in_chain(offsets, &deck_class, deck_addr, "MainDeck", &read_mem)
            .filter(|&ptr| ptr != 0)
            .and_then(|main_deck_addr| {
                let main_deck_class = object::read_runtime_class_bytes(main_deck_addr, &read_mem)?;
                list_t::read_size(offsets, &main_deck_class, main_deck_addr, &read_mem)
            });

        match main_deck_size {
            Some(card_count) if card_count > 0 => {
                resident += 1;
                println!("  [{index}] {name:?}  MainDeck _size = {card_count}  (RESIDENT)");
            }
            Some(0) => println!("  [{index}] {name:?}  MainDeck _size = 0  (empty)"),
            _ => println!("  [{index}] {name:?}  MainDeck = null  (NOT resident)"),
        }
    }
    println!("[spike] residency: {resident}/{} decks have a populated MainDeck", deck_ptrs.len());
}

// ─────────────────────────── task-2 functions ─────────────────────────────────────

fn scan_deck_candidates<F>(offsets: &MonoOffsets, images: &[u64], read_mem: F)
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    println!("\n=== candidate deck-collection classes (name contains a deck hint) ===");
    let mut seen = 0usize;
    for &image_addr in images {
        let Some(classes) = class_lookup::list_all_classes(offsets, image_addr, read_mem) else {
            continue;
        };
        for (name, class_addr) in classes {
            if DECK_CLASS_HINTS.iter().any(|hint| name.contains(hint)) {
                seen += 1;
                println!("\n-- {name} @ {class_addr:#x}");
                if let Some(class_bytes) = read_mem(class_addr, 240) {
                    dump_class_own_fields(offsets, &class_bytes, &read_mem);
                }
            }
        }
    }
    println!("\n[spike] {seen} deck-named class(es) found");
}

fn drill_papa_pointer_fields<F>(
    offsets: &MonoOffsets,
    images: &[u64],
    domain_addr: u64,
    read_mem: F,
) where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    println!("\n=== PAPA instance pointer fields (hunting for a deck anchor) ===");

    let papa_addr = match find_class_in_any(offsets, images, "PAPA", &read_mem) {
        Some(a) => a,
        None => {
            println!("[spike] PAPA class not found in any image — skipping PAPA drill");
            return;
        }
    };
    println!("[spike] PAPA class @ {papa_addr:#x}");

    let papa_bytes = match read_mem(papa_addr, CLASS_DEF_BLOB_LEN) {
        Some(b) => b,
        None => {
            println!("[spike] could not read PAPA class def bytes");
            return;
        }
    };

    let instance_field_info =
        match field::find_field_by_name(offsets, &papa_bytes, "_instance", read_mem) {
            Some(f) if f.is_static => f,
            _ => {
                println!("[spike] PAPA._instance not resolved as static — skipping PAPA drill");
                return;
            }
        };

    let storage = match vtable::static_storage_base(offsets, papa_addr, domain_addr, read_mem) {
        Some(s) => s,
        None => {
            println!("[spike] could not locate PAPA static storage — skipping PAPA drill");
            return;
        }
    };

    let papa_singleton_addr = match read_mem(storage + instance_field_info.offset as u64, 8)
        .and_then(|b| read_u64(&b))
    {
        Some(p) if p != 0 => p,
        _ => {
            println!("[spike] PAPA._instance is NULL — log in to MTGA and retry");
            return;
        }
    };
    println!("[spike] PAPA._instance singleton @ {papa_singleton_addr:#x}");

    let runtime_class = match read_object_class(papa_singleton_addr, &read_mem) {
        Some(c) => c,
        None => {
            println!("[spike] could not read PAPA singleton runtime class via vtable");
            return;
        }
    };
    let runtime_class_bytes = match read_mem(runtime_class, CLASS_DEF_BLOB_LEN) {
        Some(b) => b,
        None => {
            println!("[spike] could not read PAPA singleton runtime class bytes");
            return;
        }
    };

    println!("[spike] drilling PAPA instance pointer fields:");
    drill_pointer_fields(offsets, papa_singleton_addr, &runtime_class_bytes, &read_mem);
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

/// Drill an arbitrary object instance: resolve its runtime class via the
/// vtable, print the class name, and list its instance pointer fields. Used to
/// inspect managers surfaced by the PAPA drill (e.g. the precon deck manager)
/// and any deck object reachable from them.
fn drill_object<F>(offsets: &MonoOffsets, obj_addr: u64, read_mem: F)
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    println!("\n=== drill object @ {obj_addr:#x} ===");
    let Some(class_addr) = read_object_class(obj_addr, &read_mem) else {
        println!("[spike] could not read runtime class via vtable");
        return;
    };
    let Some(class_bytes) = read_mem(class_addr, CLASS_DEF_BLOB_LEN) else {
        println!("[spike] could not read class bytes");
        return;
    };
    match read_class_name(&class_bytes, &read_mem) {
        Some(name) => println!("[spike] runtime class = {name}"),
        None => println!("[spike] runtime class name unreadable"),
    }
    drill_pointer_fields(offsets, obj_addr, &class_bytes, &read_mem);
}

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
