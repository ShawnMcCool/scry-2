//! Spike — probe `ClientPlayerInventory` for booster-related fields.
//!
//! The walker phase 6 (currency / wildcards / vault / build hint) reads
//! seven primitive fields from `ClientPlayerInventory`. Booster
//! inventory (which sets the player has unopened packs in, and how
//! many of each) lives somewhere on the same object — most likely as
//! a `List<BoosterInventoryItem>` or `Dictionary<string,int>` field.
//!
//! This spike navigates the same chain
//! (`PAPA → InventoryManager → _inventoryServiceWrapper → m_inventory`)
//! and dumps `ClientPlayerInventory`'s full field manifest, then
//! probes a list of plausible booster-related field names to capture
//! their offset and runtime class. Output goes to stdout, intended
//! to be captured into a spike FINDING.md.
//!
//! Usage:
//!   cargo run --bin inventory-field-spike --release [-- --pid=<n>]

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
    eprintln!("[spike] mono image base=0x{:x} stitched_bytes={}", mono_base, mono_bytes.len());

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

    // Resolve PAPA._instance (static) → singleton.
    let instance_field = field::find_by_name(&offsets, &papa_bytes, 0, "_instance", read_mem)
        .filter(|f| f.is_static)
        .expect("PAPA._instance must be static");
    let storage = vtable::static_storage_base(&offsets, papa_addr, domain_addr, read_mem)
        .expect("PAPA static storage");
    let papa_singleton =
        read_u64(&read_mem(storage + instance_field.offset as u64, 8).expect("instance ptr"))
            .expect("u64");
    if papa_singleton == 0 {
        println!("[spike] PAPA._instance is NULL — MTGA not fully initialised");
        return ExitCode::from(1);
    }

    // PAPA.<InventoryManager>k__BackingField
    let im_field = field::find_by_name(&offsets, &papa_bytes, 0, "InventoryManager", read_mem)
        .filter(|f| !f.is_static)
        .expect("InventoryManager field on PAPA");
    let im_addr = read_u64(
        &read_mem(papa_singleton + im_field.offset as u64, 8).expect("im slot"),
    )
    .expect("u64");
    if im_addr == 0 {
        println!("[spike] PAPA._instance.InventoryManager is NULL");
        return ExitCode::from(1);
    }

    // InventoryManager._inventoryServiceWrapper
    let im_class_addr = read_object_class(im_addr, &read_mem).expect("im class");
    let im_class_bytes = read_mem(im_class_addr, CLASS_DEF_BLOB_LEN).expect("im class def");

    let wrap_field =
        field::find_by_name(&offsets, &im_class_bytes, 0, "_inventoryServiceWrapper", read_mem)
            .filter(|f| !f.is_static)
            .expect("_inventoryServiceWrapper field");
    let wrap_addr = read_u64(
        &read_mem(im_addr + wrap_field.offset as u64, 8).expect("wrap slot"),
    )
    .expect("u64");
    if wrap_addr == 0 {
        println!("[spike] InventoryManager._inventoryServiceWrapper is NULL");
        return ExitCode::from(1);
    }

    // wrapper.m_inventory → ClientPlayerInventory
    let wrap_class_addr = read_object_class(wrap_addr, &read_mem).expect("wrapper class");
    let wrap_class_bytes = read_mem(wrap_class_addr, CLASS_DEF_BLOB_LEN).expect("wrapper class def");

    let inv_field = field::find_by_name(&offsets, &wrap_class_bytes, 0, "m_inventory", read_mem)
        .filter(|f| !f.is_static)
        .expect("m_inventory field");
    let inv_addr = read_u64(
        &read_mem(wrap_addr + inv_field.offset as u64, 8).expect("inv slot"),
    )
    .expect("u64");
    if inv_addr == 0 {
        println!("[spike] wrapper.m_inventory is NULL");
        return ExitCode::from(1);
    }

    let inv_class_addr = read_object_class(inv_addr, &read_mem).expect("inv class");
    let inv_class_bytes = read_mem(inv_class_addr, CLASS_DEF_BLOB_LEN).expect("inv class def");

    println!("\n# ClientPlayerInventory — runtime class field manifest (object @ 0x{:x})", inv_addr);
    dump_class(&offsets, inv_class_addr, &inv_class_bytes, &read_mem);

    // Probe a list of plausible booster-related field names. Untapped's
    // decompiled types reference fields like `m_boosterCounts`,
    // `m_boosters`, `Boosters`, `BoosterCounts`, `m_boosterInventory`.
    println!("\n# Probing ClientPlayerInventory for booster-related fields");
    for candidate in &[
        "Boosters",
        "boosters",
        "m_boosters",
        "_boosters",
        "BoosterCounts",
        "boosterCounts",
        "m_boosterCounts",
        "_boosterCounts",
        "BoosterInventory",
        "boosterInventory",
        "m_boosterInventory",
        "BoostersBySetCode",
        "boostersBySetCode",
        "PendingBoosters",
        "pendingBoosters",
    ] {
        match field::find_by_name(&offsets, &inv_class_bytes, 0, candidate, read_mem) {
            Some(f) => {
                let kind = if f.is_static { "STATIC  " } else { "instance" };
                println!(
                    "  '{}' → '{}' (offset 0x{:04x}, {})",
                    candidate, f.name_found, f.offset as u32, kind
                );

                // If instance and pointer-shaped, dereference and dump
                // the runtime class one level deeper.
                if !f.is_static && f.offset >= 0 {
                    let slot = inv_addr + f.offset as u64;
                    if let Some(buf) = read_mem(slot, 8) {
                        if let Some(target) = read_u64(&buf) {
                            if target != 0 {
                                println!("    (object @ 0x{:x})", target);
                                // Try to walk as List<T>: read _items, _size,
                                // and dump the first non-null element's
                                // runtime class.
                                walk_list_first_element(target, &read_mem, &offsets);
                            } else {
                                println!("    (slot points to NULL — likely empty / not yet populated)");
                            }
                        }
                    }
                }
            }
            None => {
                println!("  '{}' → NOT FOUND", candidate);
            }
        }
    }

    ExitCode::from(0)
}

/// Walk a `List<T>` object at `list_addr` — read `_size` (offset 0x18),
/// `_items` (offset 0x10), and dump up to one populated element's
/// runtime class. The MonoArray layout is `MonoArray.vector @ 0x20`.
fn walk_list_first_element<F>(list_addr: u64, read_mem: &F, offsets: &MonoOffsets)
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let items_ptr = match read_mem(list_addr + 0x10, 8).and_then(|b| read_u64(&b)) {
        Some(p) if p != 0 => p,
        _ => {
            println!("    list._items is NULL or unreadable");
            return;
        }
    };
    let size = match read_mem(list_addr + 0x18, 4) {
        Some(b) if b.len() >= 4 => u32::from_le_bytes(b[..4].try_into().unwrap()),
        _ => 0,
    };
    println!("    list._items=0x{:x} _size={}", items_ptr, size);

    if size == 0 {
        println!("    (empty list — no element to dump)");
        return;
    }

    // MonoArray header is 0x20 bytes; element[0] sits at items_ptr + 0x20.
    // Element type is unknown — try both pointer-shaped (common case) and
    // value-type-shaped reads. For pointer-shaped, the slot is a pointer
    // to the element object.
    let element_slot = items_ptr + 0x20;

    // Try as pointer first — most C# reference types pack into List<T>
    // as a sequence of object pointers.
    if let Some(buf) = read_mem(element_slot, 8) {
        if let Some(elem_addr) = read_u64(&buf) {
            if elem_addr != 0 {
                if let Some(elem_class) = read_object_class(elem_addr, read_mem) {
                    if let Some(elem_bytes) = read_mem(elem_class, CLASS_DEF_BLOB_LEN) {
                        println!(
                            "\n    ─ list element[0] @ 0x{:x} — runtime class:",
                            elem_addr
                        );
                        dump_class(offsets, elem_class, &elem_bytes, read_mem);
                        // Also dump the first 0x40 bytes of the element
                        // object verbatim — useful when class fields look
                        // sane but values need confirming.
                        if let Some(raw) = read_mem(elem_addr, 0x40) {
                            print!("    raw bytes: ");
                            for byte in &raw[..raw.len().min(0x40)] {
                                print!("{:02x} ", byte);
                            }
                            println!();
                        }
                        return;
                    }
                }
            }
        }
    }
    println!("    could not dereference list element[0]");
}

// ─────────────────────────────────────────────────────────────────────
// helpers (duplicated from match_manager_spike for spike isolation)
// ─────────────────────────────────────────────────────────────────────

fn dump_class<F>(offsets: &MonoOffsets, class_addr: u64, class_bytes: &[u8], read_mem: &F)
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let name =
        read_class_name(class_bytes, read_mem).unwrap_or_else(|| "<unreadable>".to_string());
    let fields_ptr = mono::class_fields_ptr(offsets, class_bytes, 0).unwrap_or(0);
    let count = mono::class_def_field_count(offsets, class_bytes, 0).unwrap_or(0) as usize;
    println!(
        "class addr=0x{:x} name='{}' fields_ptr=0x{:x} field_count={}",
        class_addr, name, fields_ptr, count
    );

    if fields_ptr == 0 || count == 0 {
        return;
    }

    for i in 0..count {
        let entry_addr = match (i as u64).checked_mul(MONO_CLASS_FIELD_SIZE as u64) {
            Some(off) => fields_ptr + off,
            None => continue,
        };
        let entry_bytes = match read_mem(entry_addr, MONO_CLASS_FIELD_SIZE) {
            Some(b) => b,
            None => {
                println!("  [{i:3}] <read failed for entry @ 0x{:x}>", entry_addr);
                continue;
            }
        };

        let name_ptr = mono::field_name_ptr(offsets, &entry_bytes, 0).unwrap_or(0);
        let type_ptr = mono::field_type_ptr(offsets, &entry_bytes, 0).unwrap_or(0);
        let offset_val = mono::field_offset_value(offsets, &entry_bytes, 0).unwrap_or(0);

        let name = read_c_string(name_ptr, READ_NAME_MAX, read_mem).unwrap_or_default();
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

fn read_class_name<F>(class_bytes: &[u8], read_mem: &F) -> Option<String>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let offsets = MonoOffsets::mtga_default();
    let name_ptr = mono::class_name_ptr(&offsets, class_bytes, 0)?;
    if name_ptr == 0 {
        return None;
    }
    read_c_string(name_ptr, READ_NAME_MAX, read_mem)
}

fn read_c_string<F>(addr: u64, max: usize, read_mem: &F) -> Option<String>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    if addr == 0 {
        return None;
    }
    let bytes = read_mem(addr, max)?;
    let end = bytes.iter().position(|&b| b == 0).unwrap_or(bytes.len());
    String::from_utf8(bytes[..end].to_vec()).ok()
}

fn read_object_class<F>(obj_addr: u64, read_mem: &F) -> Option<u64>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let vtable_buf = read_mem(obj_addr, 8)?;
    let vtable_addr = read_u64(&vtable_buf)?;
    if vtable_addr == 0 {
        return None;
    }
    let klass_buf = read_mem(vtable_addr, 8)?;
    read_u64(&klass_buf)
}

fn read_u64(b: &[u8]) -> Option<u64> {
    if b.len() < 8 {
        return None;
    }
    Some(u64::from_le_bytes(b[0..8].try_into().ok()?))
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
        if let Some(addr) =
            scry2_collection_reader::walker::class_lookup::find_by_name(offsets, *img, target, read_mem)
        {
            return Some(addr);
        }
    }
    None
}

// ─────────────────────────────────────────────────────────────────────
// pid resolution (same logic as mtga-reader-poc / match-manager-spike)
// ─────────────────────────────────────────────────────────────────────

fn resolve_pid() -> Result<i32, String> {
    let args: Vec<String> = env::args().collect();
    if let Some(arg) = args.iter().find(|a| a.starts_with("--pid=")) {
        return arg["--pid=".len()..]
            .parse::<i32>()
            .map_err(|e| format!("--pid parse error: {e}"));
    }

    let mut candidates = Vec::new();
    for entry in fs::read_dir("/proc").map_err(|e| e.to_string())? {
        let entry = entry.map_err(|e| e.to_string())?;
        let name = entry.file_name();
        let name = match name.to_str() {
            Some(n) => n,
            None => continue,
        };
        let pid: i32 = match name.parse() {
            Ok(p) => p,
            Err(_) => continue,
        };
        let comm_path = format!("/proc/{}/comm", pid);
        let comm = match fs::read_to_string(&comm_path) {
            Ok(c) => c.trim().to_string(),
            Err(_) => continue,
        };
        if comm != MTGA_COMM {
            continue;
        }
        candidates.push(pid);
    }

    match candidates.len() {
        0 => Err(format!("no process with comm '{}' found", MTGA_COMM)),
        1 => Ok(candidates[0]),
        n => Err(format!("found {} candidate {} processes — pass --pid=<n>", n, MTGA_COMM)),
    }
}
