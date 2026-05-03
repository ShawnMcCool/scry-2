//! Spike — verify the `PAPA._instance.EventManager` pointer chain and
//! dump field manifests for EventManager + the first active-event
//! record (if any) so we can identify which fields the player would
//! care about (event ID, type, wins/losses, entry cost, prize state).
//!
//! Discovery output answers:
//!   * Does PAPA expose `EventManager` at offset 0x110 (instance)?
//!   * What is the runtime class of the EventManager singleton?
//!   * What collection of active-event records does it hold? (List<T> /
//!     Dictionary<K,V>)
//!   * What is the runtime class of an individual event record, and
//!     what fields does it expose?
//!
//! Output to stdout is intended to be captured into a spike FINDING.md.
//!
//! Usage:
//!   cargo run --bin event-manager-spike --release [-- --pid=<n>]

use std::env;
use std::fs;
use std::process::ExitCode;

use scry2_collection_reader::platform::{list_maps, read_bytes};
use scry2_collection_reader::walker::{
    domain, field, image_lookup,
    mono::{self, MonoOffsets, MONO_CLASS_FIELD_SIZE},
    run::{read_mono_image, CLASS_DEF_BLOB_LEN},
    vtable,
};

const MTGA_COMM: &str = "MTGA.exe";
const READ_NAME_MAX: usize = 256;
const MAX_PARENT_DEPTH: usize = 4;
const CLASS_PARENT_OFFSET: usize = 0x30;
// Hard cap on per-class field iteration. Mono's class_def_field_count
// returns garbage values for some generic / instantiated classes
// (e.g. `List<T>` reports >100 fields with empty names + heap-address
// offsets). Real MTGA classes have ≤ 50 fields; 64 leaves headroom.
const MAX_FIELDS_PER_CLASS: usize = 64;

fn main() -> ExitCode {
    let pid = match resolve_pid() {
        Ok(p) => p,
        Err(msg) => {
            eprintln!("[spike] could not resolve MTGA pid: {msg}");
            return ExitCode::from(2);
        }
    };
    eprintln!("[spike] MTGA pid = {pid}");

    let maps_owned = match list_maps(pid) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("[spike] list_maps failed: {e:?}");
            return ExitCode::from(2);
        }
    };

    let read_mem = |addr: u64, len: usize| -> Option<Vec<u8>> { read_bytes(pid, addr, len).ok() };

    let (mono_base, mono_bytes) = match read_mono_image(&maps_owned, &read_mem) {
        Some(v) => v,
        None => {
            eprintln!("[spike] could not stitch mono-2.0-bdwgc.dll image");
            return ExitCode::from(2);
        }
    };
    eprintln!(
        "[spike] mono image base=0x{:x} stitched_bytes={}",
        mono_base,
        mono_bytes.len()
    );

    let offsets = MonoOffsets::mtga_default();

    let domain_addr = match domain::find_root_domain(&mono_bytes, mono_base, read_mem) {
        Some(d) => d,
        None => {
            eprintln!("[spike] mono_get_root_domain → nullptr");
            return ExitCode::from(2);
        }
    };
    eprintln!("[spike] root_domain = 0x{:x}", domain_addr);

    let images = match image_lookup::list_all_images(&offsets, domain_addr, read_mem) {
        Some(imgs) => imgs,
        None => {
            eprintln!("[spike] could not enumerate images");
            return ExitCode::from(2);
        }
    };
    eprintln!("[spike] found {} loaded images", images.len());

    let papa_addr = match find_class_in_any(&offsets, &images, "PAPA", &read_mem) {
        Some(a) => a,
        None => {
            eprintln!("[spike] PAPA class not found in any image");
            return ExitCode::from(2);
        }
    };
    let papa_bytes = match read_mem(papa_addr, CLASS_DEF_BLOB_LEN) {
        Some(b) => b,
        None => {
            eprintln!("[spike] could not read PAPA class def");
            return ExitCode::from(2);
        }
    };

    // Resolve PAPA._instance singleton.
    let instance_field =
        match field::find_field_by_name(&offsets, &papa_bytes, "_instance", read_mem) {
            Some(f) if f.is_static => f,
            _ => {
                println!("[spike] PAPA._instance not resolved as static; stopping");
                return ExitCode::from(1);
            }
        };
    let storage = match vtable::static_storage_base(&offsets, papa_addr, domain_addr, read_mem) {
        Some(s) => s,
        None => {
            println!("[spike] could not locate PAPA's static storage");
            return ExitCode::from(1);
        }
    };
    let papa_singleton_addr =
        match read_mem(storage + instance_field.offset as u64, 8).and_then(|b| read_u64(&b)) {
            Some(p) if p != 0 => p,
            _ => {
                println!("[spike] PAPA._instance is NULL — MTGA not fully initialised?");
                return ExitCode::from(1);
            }
        };
    println!(
        "[spike] PAPA._instance singleton = 0x{:x}",
        papa_singleton_addr
    );

    // Probe a few candidate names for the EventManager anchor.
    println!("\n# Probing PAPA for EventManager anchor");
    for candidate in &[
        "EventManager",
        "_eventManager",
        "<EventManager>k__BackingField",
        "_events",
        "Events",
    ] {
        match field::find_field_by_name(&offsets, &papa_bytes, candidate, read_mem) {
            Some(f) => println!(
                "  '{}' → resolved as '{}' (offset 0x{:04x}, {})",
                candidate,
                f.name_found,
                f.offset as u32,
                if f.is_static { "STATIC" } else { "instance" }
            ),
            None => println!("  '{}' → NOT FOUND", candidate),
        }
    }

    let em_field =
        match field::find_field_by_name(&offsets, &papa_bytes, "EventManager", read_mem) {
            Some(f) if !f.is_static => f,
            Some(f) => {
                println!("\n[spike] EventManager resolved as STATIC (offset 0x{:x}) — unexpected; stopping", f.offset);
                return ExitCode::from(1);
            }
            None => {
                println!("\n[spike] EventManager NOT RESOLVED — see field dump above for the right name");
                return ExitCode::from(1);
            }
        };

    let em_slot = papa_singleton_addr + em_field.offset as u64;
    let em_addr = match read_mem(em_slot, 8).and_then(|b| read_u64(&b)) {
        Some(0) => {
            println!(
                "\n[spike] PAPA._instance.EventManager is NULL — try after MTGA finishes loading"
            );
            return ExitCode::from(0);
        }
        Some(p) => p,
        None => {
            println!("\n[spike] could not read EventManager pointer");
            return ExitCode::from(1);
        }
    };
    println!("\n[spike] PAPA._instance.EventManager = 0x{:x}", em_addr);

    let em_class = match read_object_class(em_addr, &read_mem) {
        Some(c) => c,
        None => {
            println!("[spike] could not read EventManager runtime class");
            return ExitCode::from(1);
        }
    };
    let em_class_bytes = match read_mem(em_class, CLASS_DEF_BLOB_LEN) {
        Some(b) => b,
        None => {
            println!("[spike] could not read EventManager class def");
            return ExitCode::from(1);
        }
    };

    let em_class_name = read_class_name(&em_class_bytes, &read_mem)
        .unwrap_or_else(|| "<unreadable>".to_string());
    println!(
        "\n# EventManager (object 0x{:x}) — runtime class '{}' (class addr 0x{:x})",
        em_addr, em_class_name, em_class
    );
    dump_class(&offsets, em_class, &em_class_bytes, &read_mem);

    // Walk the parent chain too — EventManager may inherit from a base
    // manager class that holds the actual collection field.
    println!("\n# EventManager — parent chain dump");
    dump_class_chain(&offsets, &em_class_bytes, 0, &read_mem);

    // Drill into every instance pointer field that looks event-bearing.
    println!("\n# Drilling EventManager instance pointer fields");
    drill_pointer_fields(&offsets, em_addr, &em_class_bytes, &read_mem, 0);

    // Deep-dive into the first few EventContext entries to expose what
    // PlayerEvent / DeckSelectContext / PostMatchContext actually carry.
    let event_contexts_field =
        match field::find_field_by_name(&offsets, &em_class_bytes, "EventContexts", read_mem) {
            Some(f) if !f.is_static => f,
            _ => {
                println!("\n[spike] EventContexts field not resolved for deep dive");
                return ExitCode::SUCCESS;
            }
        };
    let list_addr =
        match read_mem(em_addr + event_contexts_field.offset as u64, 8).and_then(|b| read_u64(&b)) {
            Some(p) if p != 0 => p,
            _ => {
                println!("\n[spike] EventContexts list pointer is null");
                return ExitCode::SUCCESS;
            }
        };
    let list_class_bytes = match read_class_def_for_object(list_addr, &read_mem) {
        Some(b) => b,
        None => return ExitCode::SUCCESS,
    };
    deep_dive_event_contexts(&offsets, list_addr, &list_class_bytes, &read_mem);

    println!("\n[spike] done.");
    ExitCode::SUCCESS
}

/// Peek the first few entries in a `List<EventContext>` and dump
/// each entry's PlayerEvent / DeckSelectContext / PostMatchContext
/// runtime classes + field manifests. The field shape on PlayerEvent
/// is what reveals win/loss state, format, entry, prize, etc.
fn deep_dive_event_contexts<F>(
    offsets: &MonoOffsets,
    list_addr: u64,
    list_class_bytes: &[u8],
    read_mem: &F,
) where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let size = field::find_field_by_name(offsets, list_class_bytes, "_size", read_mem)
        .and_then(|f| read_mem(list_addr + f.offset as u64, 4))
        .and_then(|b| {
            if b.len() < 4 {
                None
            } else {
                Some(i32::from_le_bytes([b[0], b[1], b[2], b[3]]))
            }
        })
        .unwrap_or(0);
    let items_ptr = field::find_field_by_name(offsets, list_class_bytes, "_items", read_mem)
        .and_then(|f| read_mem(list_addr + f.offset as u64, 8))
        .and_then(|b| read_u64(&b))
        .unwrap_or(0);

    println!("\n# EventContext deep dive (size={}, items=0x{:x})", size, items_ptr);

    if size <= 0 || items_ptr == 0 {
        return;
    }

    // Inspect at most the first 3 entries to bound output.
    let to_inspect = (size as usize).min(3);
    for idx in 0..to_inspect {
        let elem_slot = items_ptr + 0x20 + (idx as u64) * 8;
        let elem_ptr = match read_mem(elem_slot, 8).and_then(|b| read_u64(&b)) {
            Some(0) | None => continue,
            Some(p) => p,
        };
        let elem_class_bytes = match read_class_def_for_object(elem_ptr, read_mem) {
            Some(b) => b,
            None => continue,
        };
        let elem_class_name =
            read_class_name(&elem_class_bytes, read_mem).unwrap_or_else(|| "?".to_string());

        println!(
            "\n## EventContext[{}] addr=0x{:x} class='{}'",
            idx, elem_ptr, elem_class_name
        );
        dump_class_chain(offsets, &elem_class_bytes, 0, read_mem);

        // Drill PlayerEvent / DeckSelectContext / PostMatchContext one level deep.
        for field_name in &["PlayerEvent", "DeckSelectContext", "PostMatchContext"] {
            let f =
                match field::find_field_by_name(offsets, &elem_class_bytes, field_name, read_mem) {
                    Some(f) if !f.is_static => f,
                    _ => continue,
                };
            let inner_ptr =
                match read_mem(elem_ptr + f.offset as u64, 8).and_then(|b| read_u64(&b)) {
                    Some(0) | None => {
                        println!("  {}: NULL", field_name);
                        continue;
                    }
                    Some(p) => p,
                };
            let inner_class_bytes = match read_class_def_for_object(inner_ptr, read_mem) {
                Some(b) => b,
                None => continue,
            };
            let inner_name = read_class_name(&inner_class_bytes, read_mem)
                .unwrap_or_else(|| "?".to_string());

            println!(
                "\n  {} addr=0x{:x} class='{}'",
                field_name, inner_ptr, inner_name
            );
            dump_class_chain(offsets, &inner_class_bytes, 0, read_mem);

            if *field_name == "PlayerEvent" {
                drill_player_event_inner(offsets, inner_ptr, &inner_class_bytes, read_mem);
            }
        }
    }
}

/// Within a `BasicPlayerEvent` / `LimitedPlayerEvent`, dereference and
/// dump the runtime classes of `CourseData`, `EventInfo`, `Format`,
/// `EventUXInfo`, and (when present) `DraftPod`. These are where the
/// in-flight event state actually lives.
fn drill_player_event_inner<F>(
    offsets: &MonoOffsets,
    pe_addr: u64,
    pe_class_bytes: &[u8],
    read_mem: &F,
) where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    for field_name in &[
        "CourseData",
        "EventInfo",
        "Format",
        "EventUXInfo",
        "DraftPod",
    ] {
        let resolved =
            field::find_field_by_name_in_chain(offsets, pe_class_bytes, field_name, read_mem);
        let f = match resolved {
            Some(f) if !f.is_static => f,
            _ => {
                println!("    [PlayerEvent.{}] not resolved", field_name);
                continue;
            }
        };
        let inner_ptr = match read_mem(pe_addr + f.offset as u64, 8).and_then(|b| read_u64(&b)) {
            Some(0) | None => {
                println!("    [PlayerEvent.{}] NULL", field_name);
                continue;
            }
            Some(p) => p,
        };
        let inner_class_bytes = match read_class_def_for_object(inner_ptr, read_mem) {
            Some(b) => b,
            None => continue,
        };
        let inner_name = read_class_name(&inner_class_bytes, read_mem)
            .unwrap_or_else(|| "?".to_string());
        println!(
            "    [PlayerEvent.{}] addr=0x{:x} class='{}'",
            field_name, inner_ptr, inner_name
        );
        dump_class_chain(offsets, &inner_class_bytes, 0, read_mem);

        // EventInfo carries an `_eventInfoV3` mirror that holds the
        // wire-format event metadata (entry tokens, prizes, win/loss
        // limits, etc.). Drill into it.
        if *field_name == "EventInfo" {
            if let Some(inner_v3) =
                field::find_field_by_name_in_chain(offsets, &inner_class_bytes, "_eventInfoV3", read_mem)
            {
                if !inner_v3.is_static {
                    let v3_ptr = read_mem(inner_ptr + inner_v3.offset as u64, 8)
                        .and_then(|b| read_u64(&b))
                        .unwrap_or(0);
                    if v3_ptr != 0 {
                        if let Some(v3_bytes) = read_class_def_for_object(v3_ptr, read_mem) {
                            let v3_name = read_class_name(&v3_bytes, read_mem)
                                .unwrap_or_else(|| "?".to_string());
                            println!(
                                "      [EventInfo._eventInfoV3] addr=0x{:x} class='{}'",
                                v3_ptr, v3_name
                            );
                            dump_class_chain(offsets, &v3_bytes, 0, read_mem);
                        }
                    }
                }
            }
        }
    }
}


/// For each non-static pointer field on `class_bytes`, dereference and
/// dump the runtime class. For List<T> / Dictionary<K,V>, peek size and
/// first element class. Recurses up the parent chain so inherited
/// fields are also drilled.
fn drill_pointer_fields<F>(
    offsets: &MonoOffsets,
    obj_addr: u64,
    class_bytes: &[u8],
    read_mem: &F,
    depth: usize,
) where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    if depth > 1 {
        return;
    }

    let fields_ptr = mono::class_fields_ptr(offsets, class_bytes, 0).unwrap_or(0);
    let count = mono::class_def_field_count(offsets, class_bytes, 0).unwrap_or(0) as usize;
    let bounded = count.min(MAX_FIELDS_PER_CLASS);

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

        let is_static = if type_ptr != 0 {
            match read_mem(type_ptr, 16) {
                Some(tb) => mono::attrs_is_static(mono::type_attrs(offsets, &tb, 0).unwrap_or(0)),
                None => false,
            }
        } else {
            false
        };

        if is_static || offset_val < 0 {
            continue;
        }

        let slot = obj_addr + offset_val as u64;
        let inner = match read_mem(slot, 8).and_then(|b| read_u64(&b)) {
            Some(0) | None => continue,
            Some(p) => p,
        };

        let inner_class_bytes = match read_class_def_for_object(inner, read_mem) {
            Some(b) => b,
            None => continue,
        };
        let inner_name = read_class_name(&inner_class_bytes, read_mem)
            .unwrap_or_else(|| "?".to_string());

        println!(
            "\n[depth {}] field '{}' offset=0x{:04x} → 0x{:x} class='{}'",
            depth, name, offset_val as u32, inner, inner_name
        );

        // Always dump the inner object's class fields (parent chain too)
        // so we can see what's inside the EventManager fields.
        dump_class_chain(offsets, &inner_class_bytes, 0, read_mem);

        // For List<T> / Dictionary<K,V>, peek size and first element.
        if inner_name.starts_with("List`1") {
            peek_list(offsets, inner, &inner_class_bytes, read_mem);
        } else if inner_name.starts_with("Dictionary`2") {
            peek_dictionary(offsets, inner, &inner_class_bytes, read_mem);
        }
    }
}

fn peek_list<F>(offsets: &MonoOffsets, list_addr: u64, class_bytes: &[u8], read_mem: &F)
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let size = field::find_field_by_name(offsets, class_bytes, "_size", read_mem)
        .and_then(|f| read_mem(list_addr + f.offset as u64, 4))
        .and_then(|b| {
            if b.len() < 4 {
                None
            } else {
                Some(i32::from_le_bytes([b[0], b[1], b[2], b[3]]))
            }
        })
        .unwrap_or(-1);
    let items_ptr = field::find_field_by_name(offsets, class_bytes, "_items", read_mem)
        .and_then(|f| read_mem(list_addr + f.offset as u64, 8))
        .and_then(|b| read_u64(&b))
        .unwrap_or(0);

    println!("    List._size={} _items=0x{:x}", size, items_ptr);

    if size <= 0 || items_ptr == 0 {
        return;
    }

    // Element 0 of MonoArray<T> for reference T at items_ptr + 0x20.
    let elem_ptr = read_mem(items_ptr + 0x20, 8)
        .and_then(|b| read_u64(&b))
        .unwrap_or(0);
    if elem_ptr == 0 {
        println!("    first element ptr is 0 (val-type list?)");
        return;
    }
    let Some(elem_bytes) = read_class_def_for_object(elem_ptr, read_mem) else {
        return;
    };
    let elem_name =
        read_class_name(&elem_bytes, read_mem).unwrap_or_else(|| "?".to_string());
    println!(
        "    first element 0x{:x} class='{}'",
        elem_ptr, elem_name
    );
    println!("    element field manifest (parent chain):");
    dump_class_chain(offsets, &elem_bytes, 0, read_mem);
}

fn peek_dictionary<F>(offsets: &MonoOffsets, dict_addr: u64, class_bytes: &[u8], read_mem: &F)
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let count = field::find_field_by_name(offsets, class_bytes, "count", read_mem)
        .or_else(|| field::find_field_by_name(offsets, class_bytes, "_count", read_mem))
        .and_then(|f| read_mem(dict_addr + f.offset as u64, 4))
        .and_then(|b| {
            if b.len() < 4 {
                None
            } else {
                Some(i32::from_le_bytes([b[0], b[1], b[2], b[3]]))
            }
        })
        .unwrap_or(-1);
    println!("    Dictionary.count={}", count);

    let entries_ptr = field::find_field_by_name(offsets, class_bytes, "entries", read_mem)
        .or_else(|| field::find_field_by_name(offsets, class_bytes, "_entries", read_mem))
        .and_then(|f| read_mem(dict_addr + f.offset as u64, 8))
        .and_then(|b| read_u64(&b))
        .unwrap_or(0);
    println!("    Dictionary.entries=0x{:x}", entries_ptr);

    if entries_ptr == 0 || count <= 0 {
        return;
    }

    // Each entry in Dictionary<K,V>._entries is laid out as:
    //   { i32 hashCode, i32 next, K key, V value } with K/V padding.
    // For Dictionary<int, ref> the value at offset 0x10 of the first
    // entry would be a pointer. For Dictionary<ref, ref> first entry
    // value is at offset 0x18. We peek both to surface candidates.
    let array_header = 0x20u64;
    for off in &[0x10u64, 0x18u64] {
        let Some(b) = read_mem(entries_ptr + array_header + off, 8) else {
            continue;
        };
        let Some(p) = read_u64(&b) else { continue };
        if p == 0 {
            continue;
        }
        let Some(eb) = read_class_def_for_object(p, read_mem) else {
            continue;
        };
        let en =
            read_class_name(&eb, read_mem).unwrap_or_else(|| "?".to_string());
        println!(
            "    candidate value at entry+0x{:x} = 0x{:x} class='{}'",
            off, p, en
        );
    }
}

// ─────────────────────────────────────────────────────────────────────
// helpers (lifted from match_manager_spike)
// ─────────────────────────────────────────────────────────────────────

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

fn read_class_def_for_object<F>(obj_addr: u64, read_mem: &F) -> Option<Vec<u8>>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let vtable = read_mem(obj_addr, 8).and_then(|b| read_u64(&b))?;
    if vtable == 0 {
        return None;
    }
    let klass = read_mem(vtable, 8).and_then(|b| read_u64(&b))?;
    if klass == 0 {
        return None;
    }
    read_mem(klass, CLASS_DEF_BLOB_LEN)
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

fn dump_class<F>(offsets: &MonoOffsets, class_addr: u64, class_bytes: &[u8], read_mem: &F)
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let name = read_class_name(class_bytes, read_mem).unwrap_or_else(|| "<unreadable>".to_string());
    let fields_ptr = mono::class_fields_ptr(offsets, class_bytes, 0).unwrap_or(0);
    let count = mono::class_def_field_count(offsets, class_bytes, 0).unwrap_or(0) as usize;
    let bounded = count.min(MAX_FIELDS_PER_CLASS);
    println!(
        "class addr=0x{:x} name='{}' fields_ptr=0x{:x} field_count={} (showing {})",
        class_addr, name, fields_ptr, count, bounded
    );
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
        // Empty name = past the end of valid fields (Mono's count is
        // unreliable for some generic classes); stop iterating.
        if name.is_empty() {
            println!("  [{i:3}] <empty-name field — stopping early>");
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
            "  [{i:3}] offset=0x{:04x} {} attrs=0x{:04x} name='{}'",
            offset_val as u32,
            if is_static { "STATIC  " } else { "instance" },
            attrs,
            name,
        );
    }
}

fn dump_class_chain<F>(offsets: &MonoOffsets, class_bytes: &[u8], depth: usize, read_mem: &F)
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    if depth > MAX_PARENT_DEPTH {
        return;
    }
    let prefix = if depth == 0 {
        "this".to_string()
    } else {
        format!("parent^{}", depth)
    };
    let class_name = read_class_name(class_bytes, read_mem).unwrap_or_else(|| "?".to_string());
    println!("    [{}] class='{}'", prefix, class_name);
    dump_class_own_fields(offsets, class_bytes, read_mem);

    if class_bytes.len() < CLASS_PARENT_OFFSET + 8 {
        return;
    }
    let parent_addr = u64::from_le_bytes([
        class_bytes[CLASS_PARENT_OFFSET],
        class_bytes[CLASS_PARENT_OFFSET + 1],
        class_bytes[CLASS_PARENT_OFFSET + 2],
        class_bytes[CLASS_PARENT_OFFSET + 3],
        class_bytes[CLASS_PARENT_OFFSET + 4],
        class_bytes[CLASS_PARENT_OFFSET + 5],
        class_bytes[CLASS_PARENT_OFFSET + 6],
        class_bytes[CLASS_PARENT_OFFSET + 7],
    ]);
    if parent_addr == 0 {
        return;
    }
    let Some(parent_bytes) = read_mem(parent_addr, CLASS_DEF_BLOB_LEN) else {
        return;
    };
    let parent_name = read_class_name(&parent_bytes, read_mem).unwrap_or_default();
    if parent_name == "Object" || parent_name == "MonoBehaviour" {
        return;
    }
    dump_class_chain(offsets, &parent_bytes, depth + 1, read_mem);
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

fn find_class_in_any<F>(
    offsets: &MonoOffsets,
    images: &[u64],
    target: &str,
    read_mem: &F,
) -> Option<u64>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    for img in images {
        if let Some(addr) = scry2_collection_reader::walker::class_lookup::find_class_by_name(
            offsets, *img, target, read_mem,
        ) {
            return Some(addr);
        }
    }
    None
}

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
