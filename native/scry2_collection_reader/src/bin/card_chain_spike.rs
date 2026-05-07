//! Spike — drill from one card on the live battlefield down through
//! `BASE_CDC._model` → `CardDataAdapter._instance` → `CardInstanceData.BaseGrpId`
//! to capture the offsets the existing match-manager-spike doesn't reach.
//!
//! Output is captured and pinned into the walker as constants for the
//! Chain-2 card extraction walker.
//!
//! Usage:
//!   card-chain-spike [--pid=<n>]
//!
//! Same auto-discovery as match-manager-spike.

use std::env;
use std::fs;
use std::process::ExitCode;

use scry2_collection_reader::platform::{list_maps, read_bytes};
use scry2_collection_reader::walker::{
    domain, field, image_lookup,
    mono::{MonoOffsets, MONO_CLASS_FIELD_SIZE},
    run::{read_mono_image, CLASS_DEF_BLOB_LEN},
    vtable,
};

const MTGA_COMM: &str = "MTGA.exe";
const READ_NAME_MAX: usize = 256;

/// MonoClass.parent offset — verified by the existing match-manager
/// spike's dump_class_chain (reads u64 at class_bytes[0x30..0x38]).
const CLASS_PARENT_OFFSET: usize = 0x30;

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

    let offsets = MonoOffsets::mtga_default();

    let domain_addr = match domain::find_root_domain(&mono_bytes, mono_base, read_mem) {
        Some(d) => d,
        None => {
            eprintln!("[spike] mono_get_root_domain → nullptr");
            return ExitCode::from(2);
        }
    };

    let images = match image_lookup::list_all_images(&offsets, domain_addr, read_mem) {
        Some(i) => i,
        None => {
            eprintln!("[spike] could not enumerate images");
            return ExitCode::from(2);
        }
    };

    // Walk PAPA → MatchManager just to confirm we're in a match,
    // then walk MatchSceneManager → battlefield separately.
    let scene_class_addr =
        match find_class_in_any(&offsets, &images, "MatchSceneManager", &read_mem) {
            Some(a) => a,
            None => {
                eprintln!("[spike] MatchSceneManager class not found");
                return ExitCode::from(2);
            }
        };
    let scene_class_bytes = match read_mem(scene_class_addr, CLASS_DEF_BLOB_LEN) {
        Some(b) => b,
        None => return ExitCode::from(2),
    };

    let instance_field =
        match field::find_field_by_name(&offsets, &scene_class_bytes, "Instance", read_mem) {
            Some(f) if f.is_static => f,
            _ => {
                eprintln!("[spike] MatchSceneManager.Instance not resolvable as static");
                return ExitCode::from(2);
            }
        };

    let storage =
        match vtable::static_storage_base(&offsets, scene_class_addr, domain_addr, read_mem) {
            Some(s) => s,
            None => {
                eprintln!("[spike] could not locate scene's static storage");
                return ExitCode::from(2);
            }
        };
    let scene_singleton = match read_u64_at(storage + instance_field.offset as u64, &read_mem) {
        Some(p) if p != 0 => p,
        _ => {
            eprintln!("[spike] scene singleton NULL — no active match scene");
            return ExitCode::from(0);
        }
    };

    // Scene → _gameManager → CardHolderManager → _provider → PlayerTypeMap
    let scene_class = read_object_class(scene_singleton, &read_mem).unwrap_or(0);
    let scene_class_bytes = read_mem(scene_class, CLASS_DEF_BLOB_LEN).unwrap_or_default();
    let gm = chase(
        &offsets,
        &scene_class_bytes,
        scene_singleton,
        "_gameManager",
        &read_mem,
    )
    .expect("scene._gameManager");
    let gm_class = read_object_class(gm, &read_mem).unwrap();
    let gm_bytes = read_mem(gm_class, CLASS_DEF_BLOB_LEN).unwrap();
    let chm = chase(&offsets, &gm_bytes, gm, "CardHolderManager", &read_mem)
        .expect("gm.CardHolderManager");
    let chm_class = read_object_class(chm, &read_mem).unwrap();
    let chm_bytes = read_mem(chm_class, CLASS_DEF_BLOB_LEN).unwrap();
    let provider = chase(&offsets, &chm_bytes, chm, "_provider", &read_mem).expect("chm._provider");
    let prov_class = read_object_class(provider, &read_mem).unwrap();
    let prov_bytes = read_mem(prov_class, CLASS_DEF_BLOB_LEN).unwrap();
    let ptm = chase(&offsets, &prov_bytes, provider, "PlayerTypeMap", &read_mem)
        .expect("provider.PlayerTypeMap");

    // PTM = Dictionary<int, Dictionary<int, ICardHolder>>. Walk entries
    // looking for any seat's Battlefield holder (zone_id = 4).
    use scry2_collection_reader::walker::dict_kv;
    let ptm_class = read_object_class(ptm, &read_mem).unwrap();
    let ptm_bytes = read_mem(ptm_class, CLASS_DEF_BLOB_LEN).unwrap();
    let outer_entries_addr =
        dict_kv::entries_array_addr(&offsets, &ptm_bytes, ptm, &read_mem).unwrap();
    let outer_entries =
        dict_kv::read_int_ptr_entries(&offsets, outer_entries_addr, None, &read_mem).unwrap();

    let mut battlefield_holder: Option<u64> = None;
    let mut battlefield_seat: i32 = -1;
    for entry in &outer_entries {
        let inner_dict = entry.value;
        if inner_dict == 0 {
            continue;
        }
        let inner_class = read_object_class(inner_dict, &read_mem).unwrap_or(0);
        let inner_class_bytes = read_mem(inner_class, CLASS_DEF_BLOB_LEN).unwrap_or_default();
        let inner_entries_addr = match dict_kv::entries_array_addr(
            &offsets,
            &inner_class_bytes,
            inner_dict,
            &read_mem,
        ) {
            Some(a) => a,
            None => continue,
        };
        let inner_entries =
            match dict_kv::read_int_ptr_entries(&offsets, inner_entries_addr, None, &read_mem) {
                Some(e) => e,
                None => continue,
            };
        for ie in &inner_entries {
            if ie.key == 4 && ie.value != 0 {
                // Prefer Opponent (seat 2), but accept anything if no Opponent.
                if entry.key == 2 {
                    battlefield_holder = Some(ie.value);
                    battlefield_seat = 2;
                    break;
                } else if battlefield_holder.is_none() {
                    battlefield_holder = Some(ie.value);
                    battlefield_seat = entry.key;
                }
            }
        }
        if battlefield_seat == 2 {
            break;
        }
    }

    let battlefield_holder = match battlefield_holder {
        Some(h) => h,
        None => {
            println!("[spike] no Battlefield holder found in any seat — is a match active?");
            return ExitCode::from(0);
        }
    };
    println!(
        "[spike] battlefield holder = 0x{:x} (seat {})",
        battlefield_holder, battlefield_seat
    );

    // BattlefieldCardHolder._battlefieldLayout (own field, offset 0x168 per other spike)
    let bf_class = read_object_class(battlefield_holder, &read_mem).unwrap();
    let bf_bytes = read_mem(bf_class, CLASS_DEF_BLOB_LEN).unwrap();
    let layout_addr = chase(
        &offsets,
        &bf_bytes,
        battlefield_holder,
        "_battlefieldLayout",
        &read_mem,
    )
    .expect("BattlefieldCardHolder._battlefieldLayout");
    println!("[spike] _battlefieldLayout = 0x{:x}", layout_addr);

    // BattlefieldLayout._unattachedCardsCache (own field on BattlefieldLayout)
    let layout_class = read_object_class(layout_addr, &read_mem).unwrap();
    let layout_bytes = read_mem(layout_class, CLASS_DEF_BLOB_LEN).unwrap();
    let cards_list_addr = chase(
        &offsets,
        &layout_bytes,
        layout_addr,
        "_unattachedCardsCache",
        &read_mem,
    )
    .expect("BattlefieldLayout._unattachedCardsCache");
    println!(
        "[spike] _unattachedCardsCache (List<DuelScene_CDC>) = 0x{:x}",
        cards_list_addr
    );

    // Read _size + _items of the list
    let list_class = read_object_class(cards_list_addr, &read_mem).unwrap();
    let list_bytes = read_mem(list_class, CLASS_DEF_BLOB_LEN).unwrap();
    let size = field::find_field_by_name(&offsets, &list_bytes, "_size", read_mem)
        .and_then(|f| read_mem(cards_list_addr + f.offset as u64, 4))
        .map(|b| i32::from_le_bytes([b[0], b[1], b[2], b[3]]))
        .unwrap_or(-1);
    let items_ptr = field::find_field_by_name(&offsets, &list_bytes, "_items", read_mem)
        .and_then(|f| read_u64_at(cards_list_addr + f.offset as u64, &read_mem))
        .unwrap_or(0);
    println!(
        "[spike] battlefield cards: _size={} _items=0x{:x}",
        size, items_ptr
    );

    if size <= 0 || items_ptr == 0 {
        println!("[spike] no cards on battlefield to drill — try again with a populated board");
        return ExitCode::from(0);
    }

    // First DuelScene_CDC pointer at items_ptr + 0x20
    let first_cdc = read_u64_at(items_ptr + 0x20, &read_mem).unwrap_or(0);
    if first_cdc == 0 {
        println!("[spike] first DuelScene_CDC pointer is null");
        return ExitCode::from(1);
    }
    println!("\n[spike] first DuelScene_CDC = 0x{:x}", first_cdc);

    // Walk parent chain looking for _model (lives on BASE_CDC parent)
    let cdc_class = read_object_class(first_cdc, &read_mem).unwrap();
    let cdc_bytes = read_mem(cdc_class, CLASS_DEF_BLOB_LEN).unwrap();
    let model_field = match find_in_class_chain(&offsets, &cdc_bytes, "_model", &read_mem) {
        Some(f) => f,
        None => {
            println!("[spike] _model not found in DuelScene_CDC chain");
            return ExitCode::from(1);
        }
    };
    println!(
        "[spike] _model resolved at offset 0x{:x} (declaring class chain depth was N)",
        model_field.offset
    );

    let model_addr = read_u64_at(first_cdc + model_field.offset as u64, &read_mem).unwrap_or(0);
    if model_addr == 0 {
        println!("[spike] _model pointer is null");
        return ExitCode::from(1);
    }
    println!("[spike] _model = 0x{:x}", model_addr);

    let model_class = read_object_class(model_addr, &read_mem).unwrap();
    let model_class_bytes = read_mem(model_class, CLASS_DEF_BLOB_LEN).unwrap();
    let model_class_name = read_class_name(&model_class_bytes, &read_mem).unwrap_or_default();
    println!("[spike] _model class = '{}'", model_class_name);

    println!("\n# {} field manifest", model_class_name);
    dump_class_chain(&offsets, &model_class_bytes, 0, &read_mem);

    // Try to drill _instance
    let instance_field =
        match find_in_class_chain(&offsets, &model_class_bytes, "_instance", &read_mem) {
            Some(f) => f,
            None => {
                println!("\n[spike] _instance not found on {}", model_class_name);
                return ExitCode::from(1);
            }
        };
    println!(
        "\n[spike] _instance resolved at offset 0x{:x}",
        instance_field.offset
    );

    let instance_addr =
        read_u64_at(model_addr + instance_field.offset as u64, &read_mem).unwrap_or(0);
    if instance_addr == 0 {
        println!("[spike] _instance pointer is null");
        return ExitCode::from(1);
    }
    println!("[spike] _instance = 0x{:x}", instance_addr);

    let inst_class = read_object_class(instance_addr, &read_mem).unwrap();
    let inst_class_bytes = read_mem(inst_class, CLASS_DEF_BLOB_LEN).unwrap();
    let inst_class_name = read_class_name(&inst_class_bytes, &read_mem).unwrap_or_default();
    println!("[spike] _instance class = '{}'", inst_class_name);

    println!("\n# {} field manifest", inst_class_name);
    dump_class_chain(&offsets, &inst_class_bytes, 0, &read_mem);

    // Try to drill BaseGrpId
    let grp_field = match find_in_class_chain(&offsets, &inst_class_bytes, "BaseGrpId", &read_mem) {
        Some(f) => f,
        None => {
            println!("\n[spike] BaseGrpId not found on {}", inst_class_name);
            return ExitCode::from(1);
        }
    };
    println!(
        "\n[spike] BaseGrpId resolved at offset 0x{:x}",
        grp_field.offset
    );

    let arena_id_bytes = read_mem(instance_addr + grp_field.offset as u64, 4).unwrap_or_default();
    if arena_id_bytes.len() == 4 {
        let arena_id = i32::from_le_bytes([
            arena_id_bytes[0],
            arena_id_bytes[1],
            arena_id_bytes[2],
            arena_id_bytes[3],
        ]);
        println!(
            "\n[spike] ✓ FIRST CARD ARENA ID = {} (raw 0x{:08x})",
            arena_id, arena_id as u32
        );
    }

    // Also try IsTapped, FaceDownState fields for context
    for name in &["IsTapped", "FaceDownState", "OverlayGrpId"] {
        if let Some(f) = find_in_class_chain(&offsets, &inst_class_bytes, name, &read_mem) {
            println!("[spike] {} resolved at offset 0x{:x}", name, f.offset);
        } else {
            println!("[spike] {} not found", name);
        }
    }

    println!("\n[spike] done.");
    ExitCode::SUCCESS
}

fn chase<F>(
    offsets: &MonoOffsets,
    class_bytes: &[u8],
    obj_addr: u64,
    field_name: &str,
    read_mem: &F,
) -> Option<u64>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let f = field::find_field_by_name(offsets, class_bytes, field_name, read_mem)?;
    if f.is_static {
        return None;
    }
    read_u64_at(obj_addr + f.offset as u64, read_mem)
}

/// Walk the parent class chain looking for a field by name. Each
/// MonoClass has a `parent` pointer at offset 0x30.
fn find_in_class_chain<F>(
    offsets: &MonoOffsets,
    class_bytes: &[u8],
    target: &str,
    read_mem: &F,
) -> Option<field::ResolvedField>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    if let Some(f) = field::find_field_by_name(offsets, class_bytes, target, read_mem) {
        return Some(f);
    }
    let mut current = class_bytes.to_vec();
    for _depth in 0..6 {
        if current.len() < CLASS_PARENT_OFFSET + 8 {
            return None;
        }
        let parent_addr = u64::from_le_bytes([
            current[CLASS_PARENT_OFFSET],
            current[CLASS_PARENT_OFFSET + 1],
            current[CLASS_PARENT_OFFSET + 2],
            current[CLASS_PARENT_OFFSET + 3],
            current[CLASS_PARENT_OFFSET + 4],
            current[CLASS_PARENT_OFFSET + 5],
            current[CLASS_PARENT_OFFSET + 6],
            current[CLASS_PARENT_OFFSET + 7],
        ]);
        if parent_addr == 0 {
            return None;
        }
        let parent_bytes = read_mem(parent_addr, CLASS_DEF_BLOB_LEN)?;
        if let Some(f) = field::find_field_by_name(offsets, &parent_bytes, target, read_mem) {
            return Some(f);
        }
        current = parent_bytes;
    }
    None
}

fn dump_class_chain<F>(offsets: &MonoOffsets, class_bytes: &[u8], depth: usize, read_mem: &F)
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    if depth > 4 {
        return;
    }
    let class_name = read_class_name(class_bytes, read_mem).unwrap_or_else(|| "?".into());
    let prefix = if depth == 0 {
        "this".to_string()
    } else {
        format!("parent^{}", depth)
    };
    println!("[{}] class='{}'", prefix, class_name);

    use scry2_collection_reader::walker::mono;
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
            "  [{:2}] offset=0x{:04x} {} attrs=0x{:04x} name='{}'",
            i,
            offset_val as u32,
            if is_static { "STATIC  " } else { "instance" },
            attrs,
            name,
        );
    }

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

fn read_u64_at<F>(addr: u64, read_mem: &F) -> Option<u64>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let b = read_mem(addr, 8)?;
    if b.len() < 8 {
        None
    } else {
        Some(u64::from_le_bytes([
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
        ]))
    }
}

fn read_object_class<F>(obj: u64, read_mem: &F) -> Option<u64>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let vtable = read_u64_at(obj, read_mem)?;
    if vtable == 0 {
        return None;
    }
    let klass = read_u64_at(vtable, read_mem)?;
    if klass == 0 {
        None
    } else {
        Some(klass)
    }
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
    let entries = fs::read_dir("/proc").map_err(|e| format!("read /proc: {e}"))?;
    let mut candidates = Vec::new();
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
        let maps_raw = fs::read_to_string(format!("/proc/{}/maps", pid)).unwrap_or_default();
        if !maps_raw.contains("mono-2.0-bdwgc.dll") || !maps_raw.contains("UnityPlayer.dll") {
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
        0 => Err("no MTGA process found".into()),
        1 => Ok(candidates[0]),
        n => Err(format!("{} MTGA candidates; pass --pid=<n>", n)),
    }
}
