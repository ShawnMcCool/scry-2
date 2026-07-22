//! Spike — dump the field manifest (name, offset, static/instance,
//! parent chain) for one or more named Mono classes in a live MTGA
//! process, without needing an active match.
//!
//! Used for the battlefield per-card-ownership investigation
//! (`plans.md` section D): confirming whether `CardInstanceData`,
//! `DuelScene_CDC`, or `BaseCDC` carry a controller/owner/seat field.
//!
//! Usage:
//!   cargo run --bin class-fields-probe --release [-- --pid=<n>] [--class=Name ...]
//!
//! Defaults to probing CardInstanceData, DuelScene_CDC, BaseCDC when
//! no `--class=` args are given. `--pid` auto-discovers the MTGA.exe
//! process (same heuristic as `match-manager-spike`) when omitted.

use std::env;
use std::fs;
use std::process::ExitCode;

use scry2_collection_reader::platform::{list_maps, read_bytes};
use scry2_collection_reader::walker::{
    card_holder, class_lookup, domain, field, image_lookup, list_t, match_scene,
    mono::{self, MonoOffsets, MONO_CLASS_FIELD_SIZE},
    object,
    run::{read_mono_image, CLASS_DEF_BLOB_LEN},
};

const MTGA_COMM: &str = "MTGA.exe";
const READ_NAME_MAX: usize = 256;
const MAX_PARENT_DEPTH: usize = 4;
const CLASS_PARENT_OFFSET: usize = 0x30;

fn main() -> ExitCode {
    let pid = match resolve_pid() {
        Ok(p) => p,
        Err(msg) => {
            eprintln!("[probe] could not resolve MTGA pid: {msg}");
            return ExitCode::from(2);
        }
    };
    eprintln!("[probe] MTGA pid = {pid}");

    let targets = resolve_targets();
    eprintln!("[probe] classes: {:?}", targets);

    let maps_owned = match list_maps(pid) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("[probe] list_maps failed: {e:?}");
            return ExitCode::from(2);
        }
    };
    let read_mem = |addr: u64, len: usize| -> Option<Vec<u8>> { read_bytes(pid, addr, len).ok() };

    let (mono_base, mono_bytes) = match read_mono_image(&maps_owned, &read_mem) {
        Some(v) => v,
        None => {
            eprintln!("[probe] could not stitch mono-2.0-bdwgc.dll image");
            return ExitCode::from(2);
        }
    };

    let offsets = MonoOffsets::mtga_default();

    let domain_addr = match domain::find_root_domain(&mono_bytes, mono_base, read_mem) {
        Some(d) => d,
        None => {
            eprintln!("[probe] mono_get_root_domain → nullptr");
            return ExitCode::from(2);
        }
    };

    let images = match image_lookup::list_all_images(&offsets, domain_addr, read_mem) {
        Some(imgs) => imgs,
        None => {
            eprintln!("[probe] could not enumerate images");
            return ExitCode::from(2);
        }
    };
    eprintln!("[probe] found {} loaded images", images.len());

    if let Some(needle) = resolve_search() {
        println!("\n# classes matching '{needle}'");
        let needle_lower = needle.to_lowercase();
        for image in &images {
            let Some(classes) = class_lookup::list_all_classes(&offsets, *image, read_mem) else {
                continue;
            };
            for (class_name, class_addr) in classes {
                if class_name.to_lowercase().contains(&needle_lower) {
                    println!("  0x{class_addr:x}  {class_name}");
                }
            }
        }
        return ExitCode::SUCCESS;
    }

    if env::args().any(|a| a == "--walk-battlefield") {
        walk_battlefield(&offsets, &images, &read_mem);
        return ExitCode::SUCCESS;
    }

    if env::args().any(|a| a == "--walk-board") {
        // Exercises the actual shipped code path (same function the
        // NIF calls), not the ad-hoc drilling above — the real
        // end-to-end verification for the battlefield per-card-seat fix.
        match scry2_collection_reader::walker::run::walk_match_board(&maps_owned, read_mem) {
            Ok(Some(snapshot)) => {
                println!("\n# walk_match_board — real production path");
                for zone in &snapshot.zones {
                    println!(
                        "  seat_id={} zone_id={} arena_ids={:?}",
                        zone.seat_id, zone.zone_id, zone.arena_ids
                    );
                }
            }
            Ok(None) => println!("[probe] walk_match_board: no active match scene"),
            Err(e) => println!("[probe] walk_match_board failed: {e:?}"),
        }
        return ExitCode::SUCCESS;
    }

    for target in &targets {
        println!("\n# {target}");
        let mut found_any = false;
        for image in &images {
            let Some(classes) = class_lookup::list_all_classes(&offsets, *image, read_mem) else {
                continue;
            };
            for (class_name, class_addr) in classes {
                if class_name != *target {
                    continue;
                }
                found_any = true;
                let Some(class_bytes) = read_mem(class_addr, CLASS_DEF_BLOB_LEN) else {
                    println!("  addr=0x{class_addr:x} <read failed>");
                    continue;
                };
                println!("  addr=0x{class_addr:x}");
                dump_class_chain(&offsets, &class_bytes, 0, &read_mem);
            }
        }
        if !found_any {
            println!("  <not found in any loaded image>");
        }
    }

    ExitCode::SUCCESS
}

/// Walk the live Chain 2 battlefield (per seat) and, for each card,
/// read the raw bytes at `MtgCardInstance.Controller` (0xe0) and
/// `.Owner` (0xe8) alongside the already-known `BaseGrpId` — to learn
/// the actual value shape (small int seat id vs. object pointer) for
/// the battlefield per-card-ownership investigation.
fn walk_battlefield<F>(offsets: &MonoOffsets, images: &[u64], read_mem: &F)
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let Some(scene_class_addr) = find_class_in_any(offsets, images, "MatchSceneManager", read_mem)
    else {
        println!("[probe] MatchSceneManager class not found");
        return;
    };
    let Some(scene_class_bytes) = read_mem(scene_class_addr, CLASS_DEF_BLOB_LEN) else {
        println!("[probe] could not read MatchSceneManager class def");
        return;
    };

    let Some(domain_addr) = find_domain(read_mem) else {
        println!("[probe] could not resolve root domain for static lookup");
        return;
    };

    let Some(scene_addr) = match_scene::find_scene_singleton(
        offsets,
        scene_class_addr,
        &scene_class_bytes,
        domain_addr,
        read_mem,
    ) else {
        println!("[probe] MatchSceneManager.Instance is NULL — no active match scene");
        return;
    };
    println!("[probe] MatchSceneManager.Instance = 0x{scene_addr:x}");

    let Some((ptm_addr, ptm_class_bytes)) =
        match_scene::walk_to_player_type_map(offsets, scene_addr, read_mem)
    else {
        println!("[probe] could not walk to PlayerTypeMap");
        return;
    };

    let Some(seat_zone_map) =
        match_scene::read_seat_zone_map(offsets, ptm_addr, &ptm_class_bytes, read_mem)
    else {
        println!("[probe] could not read seat→zone map");
        return;
    };

    for seat in &seat_zone_map.seats {
        for zone in &seat.zones {
            if zone.zone_id != card_holder::ZONE_BATTLEFIELD {
                continue;
            }
            println!(
                "\n# seat={} zone=Battlefield holder_addr=0x{:x}",
                seat.seat_id, zone.holder_addr
            );
            dump_battlefield_cards(offsets, zone.holder_addr, read_mem);
        }
    }
}

fn dump_battlefield_cards<F>(offsets: &MonoOffsets, holder_addr: u64, read_mem: &F)
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let Some(holder_class_bytes) = object::read_runtime_class_bytes(holder_addr, read_mem) else {
        println!("  <could not read holder class>");
        return;
    };
    let Some(layout_addr) = object::read_instance_pointer(
        offsets,
        &holder_class_bytes,
        holder_addr,
        "_battlefieldLayout",
        read_mem,
    ) else {
        println!("  <no _battlefieldLayout>");
        return;
    };
    let Some(layout_class_bytes) = object::read_runtime_class_bytes(layout_addr, read_mem) else {
        println!("  <could not read layout class>");
        return;
    };
    let Some(list_addr) = object::read_instance_pointer(
        offsets,
        &layout_class_bytes,
        layout_addr,
        "_unattachedCardsCache",
        read_mem,
    ) else {
        println!("  <no _unattachedCardsCache>");
        return;
    };
    let Some(list_class_bytes) = object::read_runtime_class_bytes(list_addr, read_mem) else {
        println!("  <could not read list class>");
        return;
    };
    let cdc_pointers = list_t::read_pointer_list(offsets, &list_class_bytes, list_addr, read_mem);
    println!("  {} card(s) in _unattachedCardsCache", cdc_pointers.len());

    for cdc_addr in cdc_pointers {
        dump_one_card(offsets, cdc_addr, read_mem);
    }
}

fn dump_one_card<F>(offsets: &MonoOffsets, cdc_addr: u64, read_mem: &F)
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let Some(cdc_class_bytes) = object::read_runtime_class_bytes(cdc_addr, read_mem) else {
        println!("  cdc=0x{cdc_addr:x} <class read failed>");
        return;
    };
    let Some(model_field) =
        field::find_field_by_name_in_chain(offsets, &cdc_class_bytes, "_model", read_mem)
    else {
        println!("  cdc=0x{cdc_addr:x} <no _model field>");
        return;
    };
    let Some(model_addr) =
        read_mem(cdc_addr + model_field.offset as u64, 8).and_then(|b| read_u64(&b))
    else {
        println!("  cdc=0x{cdc_addr:x} <could not read _model pointer>");
        return;
    };
    if model_addr == 0 {
        println!("  cdc=0x{cdc_addr:x} _model=NULL");
        return;
    }

    let Some(model_class_bytes) = object::read_runtime_class_bytes(model_addr, read_mem) else {
        println!("  cdc=0x{cdc_addr:x} <could not read model class>");
        return;
    };
    let Some(instance_field) =
        field::find_field_by_name_in_chain(offsets, &model_class_bytes, "_instance", read_mem)
    else {
        println!("  cdc=0x{cdc_addr:x} <no _instance field>");
        return;
    };
    let Some(instance_addr) =
        read_mem(model_addr + instance_field.offset as u64, 8).and_then(|b| read_u64(&b))
    else {
        println!("  cdc=0x{cdc_addr:x} <could not read _instance pointer>");
        return;
    };
    if instance_addr == 0 {
        println!("  cdc=0x{cdc_addr:x} _instance=NULL");
        return;
    }

    // BaseGrpId is resolved by name elsewhere (card_holder::arena_id_for_cdc);
    // here we read it directly plus the two ownership candidates.
    let base_grp_id = field::find_field_by_name_in_chain(
        offsets,
        &object::read_runtime_class_bytes(instance_addr, read_mem).unwrap_or_default(),
        "BaseGrpId",
        read_mem,
    )
    .and_then(|f| read_mem(instance_addr + f.offset as u64, 4))
    .and_then(|b| {
        if b.len() < 4 {
            None
        } else {
            Some(i32::from_le_bytes([b[0], b[1], b[2], b[3]]))
        }
    });

    // Controller / Owner — offsets confirmed live via class-fields-probe
    // on MtgCardInstance: 0xe0 / 0xe8. Read as raw 8 bytes so we can
    // print both interpretations (small int vs. pointer) without
    // assuming the type ahead of time.
    let controller_raw = read_mem(instance_addr + 0xe0, 8);
    let owner_raw = read_mem(instance_addr + 0xe8, 8);

    println!(
        "  cdc=0x{:x} instance=0x{:x} BaseGrpId={:?}",
        cdc_addr, instance_addr, base_grp_id
    );
    print_dual_interpretation("    Controller", controller_raw.clone());
    print_dual_interpretation("    Owner", owner_raw.clone());
    if let Some(ptr) = controller_raw.as_ref().and_then(|b| read_u64(b)) {
        deref_boxed_value("    Controller ->", ptr, read_mem);
    }
    if let Some(ptr) = owner_raw.as_ref().and_then(|b| read_u64(b)) {
        deref_boxed_value("    Owner ->", ptr, read_mem);
    }
}

/// Dereference a pointer field whose target's identity is unknown —
/// print its runtime class name plus the first bytes past the
/// standard 0x10 object header, in case it's a boxed primitive/enum
/// (`GREPlayerNum` boxed as `object`, `Nullable<int>`, etc.).
fn deref_boxed_value<F>(label: &str, ptr: u64, read_mem: &F)
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    if ptr == 0 {
        println!("{label} NULL");
        return;
    }
    let class_name = object::read_runtime_class_bytes(ptr, read_mem)
        .and_then(|cb| {
            let read_mem2 = read_mem;
            (|| -> Option<String> {
                if cb.len() < 0x50 {
                    return None;
                }
                let name_ptr = u64::from_le_bytes([
                    cb[0x48], cb[0x49], cb[0x4a], cb[0x4b], cb[0x4c], cb[0x4d], cb[0x4e], cb[0x4f],
                ]);
                let bytes = read_mem2(name_ptr, READ_NAME_MAX)?;
                let nul = bytes.iter().position(|b| *b == 0).unwrap_or(bytes.len());
                String::from_utf8(bytes[..nul].to_vec()).ok()
            })()
        })
        .unwrap_or_else(|| "?".to_string());
    let payload = read_mem(ptr + 0x10, 8);
    let payload_str = match payload {
        Some(bytes) if bytes.len() >= 8 => {
            let as_i32 = i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
            let as_u64 = u64::from_le_bytes([
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            ]);
            format!("payload_i32={as_i32} payload_u64=0x{as_u64:x}")
        }
        _ => "<payload read failed>".to_string(),
    };

    // MtgPlayer.ClientPlayerEnum (offset 0x13c) / ControllerId (0x11c) —
    // confirmed live via class-fields-probe --class=MtgPlayer. These are
    // candidates for the stable per-player identity, since the MtgPlayer
    // *object* pointer itself appears to churn across GRE update batches.
    let client_player_enum = read_mem(ptr + 0x13c, 4)
        .filter(|b| b.len() >= 4)
        .map(|b| i32::from_le_bytes([b[0], b[1], b[2], b[3]]));
    let controller_id = read_mem(ptr + 0x11c, 4)
        .filter(|b| b.len() >= 4)
        .map(|b| i32::from_le_bytes([b[0], b[1], b[2], b[3]]));

    println!(
        "{label} 0x{ptr:x} class='{class_name}' {payload_str} ClientPlayerEnum={:?} ControllerId={:?}",
        client_player_enum, controller_id
    );
}

fn print_dual_interpretation(label: &str, raw: Option<Vec<u8>>) {
    match raw {
        Some(bytes) if bytes.len() >= 8 => {
            let as_i32 = i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
            let as_u64 = u64::from_le_bytes([
                bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            ]);
            println!("{label}: as_i32={as_i32} as_u64_ptr=0x{as_u64:x}");
        }
        _ => println!("{label}: <read failed>"),
    }
}

fn find_domain<F>(read_mem: F) -> Option<u64>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    // Re-derive mono_base/mono_bytes independently since main() doesn't
    // thread them through to this helper.
    let pid = resolve_pid().ok()?;
    let maps_owned = list_maps(pid).ok()?;
    let (mono_base, mono_bytes) = read_mono_image(&maps_owned, &read_mem)?;
    domain::find_root_domain(&mono_bytes, mono_base, read_mem)
}

fn resolve_search() -> Option<String> {
    env::args()
        .skip(1)
        .find_map(|arg| arg.strip_prefix("--search=").map(|s| s.to_string()))
}

fn resolve_targets() -> Vec<String> {
    let explicit: Vec<String> = env::args()
        .skip(1)
        .filter_map(|arg| arg.strip_prefix("--class=").map(|s| s.to_string()))
        .collect();
    if explicit.is_empty() {
        vec![
            "CardInstanceData".to_string(),
            "DuelScene_CDC".to_string(),
            "BaseCDC".to_string(),
        ]
    } else {
        explicit
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
        format!("parent^{depth}")
    };
    let class_name = read_class_name(class_bytes, read_mem).unwrap_or_else(|| "?".to_string());
    println!("  [{prefix}] class='{class_name}'");

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
            None => continue,
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
            "    [{i:2}] offset=0x{:04x} {} attrs=0x{:04x} name='{}'",
            offset_val as u32,
            if is_static { "STATIC  " } else { "instance" },
            attrs,
            name,
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
        if let Some(addr) = class_lookup::find_class_by_name(offsets, *img, target, read_mem) {
            return Some(addr);
        }
    }
    None
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

        let comm = fs::read_to_string(format!("/proc/{pid}/comm")).unwrap_or_default();
        if comm.trim() != MTGA_COMM {
            continue;
        }

        let maps_raw = match fs::read_to_string(format!("/proc/{pid}/maps")) {
            Ok(s) => s,
            Err(_) => continue,
        };
        if !maps_raw.contains("mono-2.0-bdwgc.dll") {
            continue;
        }
        if !maps_raw.contains("UnityPlayer.dll") {
            continue;
        }

        let status = fs::read_to_string(format!("/proc/{pid}/status")).unwrap_or_default();
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
        0 => Err("no MTGA.exe host process found (checked comm, mono dll, UnityPlayer dll, VmRSS > 500MB)".to_string()),
        1 => Ok(candidates[0]),
        _ => Err(format!(
            "multiple MTGA.exe candidates found: {candidates:?} — pass --pid= explicitly"
        )),
    }
}
