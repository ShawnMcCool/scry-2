//! Spike — verify the `PAPA._instance.MatchManager` pointer chain
//! against a live MTGA process and dump field manifests for both PAPA
//! and (if reachable) MatchManager's runtime class.
//!
//! Discovery output answers:
//!   * Does PAPA expose `MatchManager` (or `<MatchManager>k__BackingField`)
//!     as an instance field?
//!   * What is its runtime class name when an active match is in flight?
//!   * What instance fields does MatchManager carry, at what offsets?
//!   * Are `LocalPlayerInfo` / `OpponentInfo` / `Event` present?
//!
//! Output to stdout is intended to be captured into a spike FINDING.md.
//!
//! Usage:
//!   cargo run --bin match-manager-spike --release [-- --pid=<n>]
//!
//! When `--pid` is omitted, the spike auto-discovers a single MTGA
//! Unity host process (comm == "MTGA.exe", mono-2.0-bdwgc.dll mapped,
//! UnityPlayer.dll mapped, VmRSS > 500 MB).

use std::env;
use std::fs;
use std::process::ExitCode;

use scry2_collection_reader::platform::{list_maps, read_bytes};
use scry2_collection_reader::walker::{
    dict_kv, domain, field, image_lookup,
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
    eprintln!("[spike] PAPA class = 0x{:x}", papa_addr);

    let papa_bytes = match read_mem(papa_addr, CLASS_DEF_BLOB_LEN) {
        Some(b) => b,
        None => {
            eprintln!("[spike] could not read PAPA class def");
            return ExitCode::from(2);
        }
    };

    println!("\n# PAPA — class field manifest");
    dump_class(&offsets, papa_addr, &papa_bytes, &read_mem);

    // Resolve PAPA._instance — handles both literal `_instance` and
    // `<Instance>k__BackingField` per spike 5.
    let instance_field = match field::find_by_name(&offsets, &papa_bytes, 0, "_instance", read_mem)
    {
        Some(f) => f,
        None => {
            println!("\n[spike] PAPA._instance — NOT RESOLVED — stopping");
            return ExitCode::from(1);
        }
    };

    if !instance_field.is_static {
        println!(
            "\n[spike] PAPA._instance resolved as INSTANCE field (offset 0x{:x}) — expected static; stopping",
            instance_field.offset
        );
        return ExitCode::from(1);
    }

    let storage = match vtable::static_storage_base(&offsets, papa_addr, domain_addr, read_mem) {
        Some(s) => s,
        None => {
            println!("\n[spike] could not locate PAPA's static storage via vtable");
            return ExitCode::from(1);
        }
    };
    let static_addr = storage + instance_field.offset as u64;
    let papa_singleton_addr = match read_mem(static_addr, 8).and_then(|b| read_u64(&b)) {
        Some(p) if p != 0 => p,
        Some(_) => {
            println!(
                "\n[spike] PAPA._instance is NULL — is MTGA fully initialised? (pid {pid})"
            );
            return ExitCode::from(1);
        }
        None => {
            println!("\n[spike] could not read PAPA._instance pointer");
            return ExitCode::from(1);
        }
    };

    println!("\n[spike] PAPA._instance singleton = 0x{:x} (resolved via '{}')",
             papa_singleton_addr, instance_field.name_found);

    // Try to resolve MatchManager — both literal and backing-field
    // variants are tried by find_by_name automatically.
    println!("\n# Probing PAPA for MatchManager");
    for candidate in &["MatchManager", "_matchManager", "matchManager"] {
        match field::find_by_name(&offsets, &papa_bytes, 0, candidate, read_mem) {
            Some(f) => {
                println!(
                    "  candidate '{}' → resolved as '{}' (offset 0x{:04x}, {})",
                    candidate,
                    f.name_found,
                    f.offset as u32,
                    if f.is_static { "STATIC" } else { "instance" }
                );
            }
            None => {
                println!("  candidate '{}' → NOT FOUND", candidate);
            }
        }
    }

    // Use the canonical name MatchManager and proceed if it resolves
    // as an instance field.
    let mm_field = match field::find_by_name(&offsets, &papa_bytes, 0, "MatchManager", read_mem) {
        Some(f) if !f.is_static => f,
        Some(f) => {
            println!(
                "\n[spike] MatchManager resolved but as STATIC (offset 0x{:x}) — unexpected; stopping",
                f.offset
            );
            return ExitCode::from(1);
        }
        None => {
            println!(
                "\n[spike] MatchManager NOT RESOLVED on PAPA — examine the field dump above for the right name"
            );
            return ExitCode::from(1);
        }
    };

    let mm_slot_addr = papa_singleton_addr + mm_field.offset as u64;
    let mm_addr = match read_mem(mm_slot_addr, 8).and_then(|b| read_u64(&b)) {
        Some(0) => {
            println!(
                "\n[spike] PAPA._instance.MatchManager is NULL — likely no active match. Try again from inside a match."
            );
            return ExitCode::from(0);
        }
        Some(p) => p,
        None => {
            println!("\n[spike] could not read PAPA._instance.MatchManager pointer");
            return ExitCode::from(1);
        }
    };
    println!("\n[spike] PAPA._instance.MatchManager = 0x{:x}", mm_addr);

    // Get MatchManager's runtime class via vtable.
    let mm_class_addr = match read_object_class(mm_addr, &read_mem) {
        Some(c) => c,
        None => {
            println!("[spike] could not read MatchManager.vtable.klass");
            return ExitCode::from(1);
        }
    };
    let mm_class_bytes = match read_mem(mm_class_addr, CLASS_DEF_BLOB_LEN) {
        Some(b) => b,
        None => {
            println!("[spike] could not read MatchManager class def");
            return ExitCode::from(1);
        }
    };

    println!("\n# MatchManager — runtime class field manifest");
    dump_class(&offsets, mm_class_addr, &mm_class_bytes, &read_mem);

    // Probe for the fields documented in untapped's blueprint.
    println!("\n# Probing MatchManager for known untapped-blueprint field names");
    for candidate in &[
        "LocalPlayerInfo",
        "OpponentInfo",
        "Event",
        "_localPlayerInfo",
        "_opponentInfo",
        "_event",
    ] {
        match field::find_by_name(&offsets, &mm_class_bytes, 0, candidate, read_mem) {
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

    // For each present player-info / event field, dereference and dump
    // the runtime class field manifest one level deeper.
    let mut player_addrs: Vec<(&str, u64)> = Vec::new();
    for candidate in &["LocalPlayerInfo", "OpponentInfo", "Event"] {
        if let Some(f) = field::find_by_name(&offsets, &mm_class_bytes, 0, candidate, read_mem) {
            if f.is_static {
                continue;
            }
            let slot = mm_addr + f.offset as u64;
            let target_addr = match read_mem(slot, 8).and_then(|b| read_u64(&b)) {
                Some(0) => {
                    println!(
                        "\n[{}] field present but pointer is NULL",
                        candidate
                    );
                    continue;
                }
                Some(p) => p,
                None => {
                    println!("\n[{}] could not read pointer slot", candidate);
                    continue;
                }
            };
            let target_class = match read_object_class(target_addr, &read_mem) {
                Some(c) => c,
                None => {
                    println!("\n[{}] could not read runtime class", candidate);
                    continue;
                }
            };
            let target_bytes = match read_mem(target_class, CLASS_DEF_BLOB_LEN) {
                Some(b) => b,
                None => {
                    println!("\n[{}] could not read class def", candidate);
                    continue;
                }
            };
            println!("\n# {} (object 0x{:x}) — runtime class field manifest", candidate, target_addr);
            dump_class(&offsets, target_class, &target_bytes, &read_mem);
            if *candidate == "LocalPlayerInfo" || *candidate == "OpponentInfo" {
                player_addrs.push((candidate, target_addr));
            }
        }
    }

    // Read primitive rank/seat values from each PlayerInfo. These
    // are the actual log-gap-filler numbers — the field names alone
    // don't tell us whether the values are populated.
    for (label, player_addr) in &player_addrs {
        let player_class = match read_object_class(*player_addr, &read_mem) {
            Some(c) => c,
            None => continue,
        };
        let player_bytes = match read_mem(player_class, CLASS_DEF_BLOB_LEN) {
            Some(b) => b,
            None => continue,
        };
        println!("\n# {} primitive values", label);
        for (name, width) in &[
            ("SeatId", 4),
            ("TeamId", 4),
            ("RankingClass", 4),
            ("RankingTier", 4),
            ("MythicPercentile", 4),
            ("MythicPlacement", 4),
            ("IsWotc", 1),
        ] {
            let resolved =
                match field::find_by_name(&offsets, &player_bytes, 0, name, read_mem) {
                    Some(r) if !r.is_static => r,
                    _ => {
                        println!("  {} → not resolved", name);
                        continue;
                    }
                };
            let off = resolved.offset as u32;
            let addr = *player_addr + resolved.offset as u64;
            let bytes = match read_mem(addr, *width) {
                Some(b) => b,
                None => {
                    println!("  {} @ 0x{:04x} → read failed", name, off);
                    continue;
                }
            };
            match *width {
                4 => {
                    let int_val =
                        i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
                    let float_val =
                        f32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
                    println!(
                        "  {} @ 0x{:04x} = i32:{} (raw 0x{:08x}, as_f32:{:.4})",
                        name, off, int_val, int_val as u32, float_val
                    );
                }
                1 => {
                    println!("  {} @ 0x{:04x} = u8:{}", name, off, bytes[0]);
                }
                _ => {}
            }
        }
    }

    // Now drill one level deeper into _deckCards / _sideboardCards /
    // CommanderGrpIds for each PlayerInfo we found, to see whether
    // MTGA's client carries opponent deck identities at all.
    for (label, player_addr) in &player_addrs {
        let player_class = match read_object_class(*player_addr, &read_mem) {
            Some(c) => c,
            None => continue,
        };
        let player_bytes = match read_mem(player_class, CLASS_DEF_BLOB_LEN) {
            Some(b) => b,
            None => continue,
        };
        for inner in &["_deckCards", "_sideboardCards", "CommanderGrpIds", "_screenName"] {
            let f = match field::find_by_name(&offsets, &player_bytes, 0, inner, read_mem) {
                Some(f) if !f.is_static => f,
                _ => continue,
            };
            let slot = *player_addr + f.offset as u64;
            let inner_addr = match read_mem(slot, 8).and_then(|b| read_u64(&b)) {
                Some(0) => {
                    println!("\n[{}.{}] field present but pointer is NULL", label, inner);
                    continue;
                }
                Some(p) => p,
                None => continue,
            };

            // For string-shaped fields, try to print value directly.
            // MonoString layout: vtable(8) + sync(8) + length(4) + chars(UTF-16).
            if *inner == "_screenName" {
                if let Some(s) = read_mono_string(inner_addr, &read_mem) {
                    println!("\n[{}.{}] addr=0x{:x} value={:?}", label, inner, inner_addr, s);
                    continue;
                }
            }

            let inner_class = match read_object_class(inner_addr, &read_mem) {
                Some(c) => c,
                None => continue,
            };
            let inner_bytes = match read_mem(inner_class, CLASS_DEF_BLOB_LEN) {
                Some(b) => b,
                None => continue,
            };
            let cls_name = read_class_name(&inner_bytes, &read_mem)
                .unwrap_or_else(|| "<unreadable>".to_string());
            println!(
                "\n[{}.{}] addr=0x{:x} runtime_class='{}' (class addr 0x{:x})",
                label, inner, inner_addr, cls_name, inner_class
            );

            // For List<T>: print _items pointer + _size + _version if
            // the class looks like List`1.
            if cls_name.starts_with("List`1") {
                if let Some(size_field) =
                    field::find_by_name(&offsets, &inner_bytes, 0, "_size", read_mem)
                {
                    let sz = read_mem(inner_addr + size_field.offset as u64, 4)
                        .and_then(|b| {
                            if b.len() < 4 {
                                None
                            } else {
                                Some(i32::from_le_bytes([b[0], b[1], b[2], b[3]]))
                            }
                        })
                        .unwrap_or(-1);
                    println!("    List._size = {}", sz);
                }
                if let Some(items_field) =
                    field::find_by_name(&offsets, &inner_bytes, 0, "_items", read_mem)
                {
                    let items_ptr = read_mem(inner_addr + items_field.offset as u64, 8)
                        .and_then(|b| read_u64(&b))
                        .unwrap_or(0);
                    println!("    List._items pointer = 0x{:x}", items_ptr);
                    if items_ptr != 0 {
                        // MonoArray.max_length at 0x18 per skill.
                        if let Some(b) = read_mem(items_ptr + 0x18, 8) {
                            if b.len() >= 8 {
                                let max_len = u64::from_le_bytes([
                                    b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                                ]);
                                println!("    Array.max_length = {}", max_len);
                            }
                        }
                        // First few elements (assume i32 elements for
                        // CommanderGrpIds; for _deckCards/_sideboardCards
                        // the element type may be a struct — printing as
                        // i32 is just a probe).
                        let elements_addr = items_ptr + 0x20;
                        if let Some(b) = read_mem(elements_addr, 64) {
                            print!("    first 8 i32s:");
                            for i in 0..8 {
                                let off = i * 4;
                                if b.len() >= off + 4 {
                                    let v =
                                        i32::from_le_bytes([b[off], b[off + 1], b[off + 2], b[off + 3]]);
                                    print!(" {}", v);
                                }
                            }
                            println!();
                        }
                    }
                }
            }
        }
    }

    // ─── Chain 2 probe: MatchSceneManager / GameManager / CardHolder ───
    println!("\n# Chain 2 — MatchSceneManager probe");
    let scene_candidates = [
        "MatchSceneManager",
        "DuelSceneManager",
        "GameSceneManager",
        "MatchScene",
        "DuelScene",
    ];
    let mut scene_class_addr: Option<u64> = None;
    let mut scene_class_name: &'static str = "";
    for name in &scene_candidates {
        if let Some(addr) = find_class_in_any(&offsets, &images, name, &read_mem) {
            println!("  class '{}' found at 0x{:x}", name, addr);
            scene_class_addr = Some(addr);
            scene_class_name = name;
            break;
        } else {
            println!("  class '{}' not found", name);
        }
    }

    let scene_class_addr = match scene_class_addr {
        Some(a) => a,
        None => {
            println!(
                "[spike] no scene-manager class found by name; need to widen the candidate list"
            );
            return ExitCode::SUCCESS;
        }
    };

    let scene_class_bytes = match read_mem(scene_class_addr, CLASS_DEF_BLOB_LEN) {
        Some(b) => b,
        None => {
            println!("[spike] could not read scene class def");
            return ExitCode::SUCCESS;
        }
    };

    println!("\n# {} — class field manifest", scene_class_name);
    dump_class(&offsets, scene_class_addr, &scene_class_bytes, &read_mem);

    // Try common Unity-singleton anchors.
    let anchor_field = ["Instance", "_instance", "<Instance>k__BackingField"]
        .iter()
        .find_map(|name| {
            field::find_by_name(&offsets, &scene_class_bytes, 0, name, read_mem)
                .map(|f| (*name, f))
        });

    let (anchor_name, anchor_resolved) = match anchor_field {
        Some(t) => t,
        None => {
            println!(
                "\n[spike] no Instance static on {} — may be resolved via Unity scene lookup instead of a static singleton",
                scene_class_name
            );
            return ExitCode::SUCCESS;
        }
    };

    if !anchor_resolved.is_static {
        println!(
            "\n[spike] {}.{} resolved as instance (offset 0x{:x}) — not a static singleton",
            scene_class_name, anchor_name, anchor_resolved.offset
        );
        return ExitCode::SUCCESS;
    }

    let storage = match vtable::static_storage_base(&offsets, scene_class_addr, domain_addr, read_mem) {
        Some(s) => s,
        None => {
            println!("[spike] could not locate {}'s static storage", scene_class_name);
            return ExitCode::SUCCESS;
        }
    };
    let scene_singleton =
        match read_mem(storage + anchor_resolved.offset as u64, 8).and_then(|b| read_u64(&b)) {
            Some(0) | None => {
                println!(
                    "\n[spike] {}.{} = NULL — no active match scene",
                    scene_class_name, anchor_name
                );
                return ExitCode::SUCCESS;
            }
            Some(p) => p,
        };
    println!(
        "\n[spike] {}.{} singleton = 0x{:x} (resolved via '{}')",
        scene_class_name, anchor_name, scene_singleton, anchor_resolved.name_found
    );

    // From here, walk to _gameManager, then to CardHolderManager._provider.PlayerTypeMap.
    let scene_runtime_class = match read_object_class(scene_singleton, &read_mem) {
        Some(c) => c,
        None => {
            println!("[spike] could not read scene singleton runtime class");
            return ExitCode::SUCCESS;
        }
    };
    let scene_runtime_bytes = match read_mem(scene_runtime_class, CLASS_DEF_BLOB_LEN) {
        Some(b) => b,
        None => return ExitCode::SUCCESS,
    };
    println!(
        "\n# {} runtime class field manifest",
        read_class_name(&scene_runtime_bytes, &read_mem).unwrap_or_default()
    );
    dump_class(&offsets, scene_runtime_class, &scene_runtime_bytes, &read_mem);

    // Try to follow _gameManager → CardHolderManager → _provider → PlayerTypeMap.
    let game_manager_addr =
        match field::find_by_name(&offsets, &scene_runtime_bytes, 0, "_gameManager", read_mem) {
            Some(f) if !f.is_static => {
                read_mem(scene_singleton + f.offset as u64, 8).and_then(|b| read_u64(&b))
            }
            _ => None,
        };

    let game_manager_addr = match game_manager_addr {
        Some(p) if p != 0 => p,
        _ => {
            println!("\n[spike] _gameManager not resolved or NULL; stopping");
            return ExitCode::SUCCESS;
        }
    };
    println!("\n[spike] _gameManager = 0x{:x}", game_manager_addr);

    let gm_class = match read_object_class(game_manager_addr, &read_mem) {
        Some(c) => c,
        None => return ExitCode::SUCCESS,
    };
    let gm_bytes = match read_mem(gm_class, CLASS_DEF_BLOB_LEN) {
        Some(b) => b,
        None => return ExitCode::SUCCESS,
    };
    println!(
        "\n# {} (_gameManager) runtime class field manifest",
        read_class_name(&gm_bytes, &read_mem).unwrap_or_default()
    );
    dump_class(&offsets, gm_class, &gm_bytes, &read_mem);

    // CardHolderManager.
    let chm_addr =
        match field::find_by_name(&offsets, &gm_bytes, 0, "CardHolderManager", read_mem) {
            Some(f) if !f.is_static => {
                read_mem(game_manager_addr + f.offset as u64, 8).and_then(|b| read_u64(&b))
            }
            _ => None,
        };
    let chm_addr = match chm_addr {
        Some(p) if p != 0 => p,
        _ => {
            println!("\n[spike] CardHolderManager not resolved or NULL");
            return ExitCode::SUCCESS;
        }
    };
    println!("\n[spike] CardHolderManager = 0x{:x}", chm_addr);
    let chm_class = match read_object_class(chm_addr, &read_mem) {
        Some(c) => c,
        None => return ExitCode::SUCCESS,
    };
    let chm_bytes = match read_mem(chm_class, CLASS_DEF_BLOB_LEN) {
        Some(b) => b,
        None => return ExitCode::SUCCESS,
    };
    println!(
        "\n# CardHolderManager runtime class field manifest"
    );
    dump_class(&offsets, chm_class, &chm_bytes, &read_mem);

    // _provider → PlayerTypeMap.
    let provider_addr =
        match field::find_by_name(&offsets, &chm_bytes, 0, "_provider", read_mem) {
            Some(f) if !f.is_static => {
                read_mem(chm_addr + f.offset as u64, 8).and_then(|b| read_u64(&b))
            }
            _ => None,
        };
    let provider_addr = match provider_addr {
        Some(p) if p != 0 => p,
        _ => {
            println!("\n[spike] _provider not resolved or NULL");
            return ExitCode::SUCCESS;
        }
    };
    println!("\n[spike] CardHolderManager._provider = 0x{:x}", provider_addr);
    let prov_class = match read_object_class(provider_addr, &read_mem) {
        Some(c) => c,
        None => return ExitCode::SUCCESS,
    };
    let prov_bytes = match read_mem(prov_class, CLASS_DEF_BLOB_LEN) {
        Some(b) => b,
        None => return ExitCode::SUCCESS,
    };
    println!("\n# _provider runtime class field manifest");
    dump_class(&offsets, prov_class, &prov_bytes, &read_mem);

    let ptm_addr =
        match field::find_by_name(&offsets, &prov_bytes, 0, "PlayerTypeMap", read_mem) {
            Some(f) if !f.is_static => {
                read_mem(provider_addr + f.offset as u64, 8).and_then(|b| read_u64(&b))
            }
            _ => None,
        };

    let ptm_addr = match ptm_addr {
        Some(p) if p != 0 => {
            println!("\n[spike] _provider.PlayerTypeMap = 0x{:x}", p);
            p
        }
        _ => {
            println!("\n[spike] PlayerTypeMap not resolved or NULL");
            return ExitCode::SUCCESS;
        }
    };

    // ─── Chain 2 deep dive ───────────────────────────────────────────
    // Walks PlayerTypeMap entries → inner zone dicts → individual
    // CardHolder objects, dumping each holder's runtime class +
    // field manifest. The data produced here is the input for
    // designing the holder walker.
    chain2_deep_dive(&offsets, ptm_addr, &read_mem);

    println!("\n[spike] done.");
    ExitCode::SUCCESS
}

// ─────────────────────────────────────────────────────────────────────
// Chain 2 deep dive
// ─────────────────────────────────────────────────────────────────────

const SEAT_NAMES: &[(i32, &str)] = &[
    (0, "Invalid"),
    (1, "LocalPlayer"),
    (2, "Opponent"),
    (3, "Teammate"),
];

fn seat_name(id: i32) -> String {
    SEAT_NAMES
        .iter()
        .find_map(|(k, v)| if *k == id { Some(v.to_string()) } else { None })
        .unwrap_or_else(|| format!("seat_{}", id))
}

fn chain2_deep_dive<F>(offsets: &MonoOffsets, ptm_addr: u64, read_mem: &F)
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    println!("\n# Chain 2 — PlayerTypeMap entry walk\n");

    let outer_class_bytes = match read_class_def_for_object(ptm_addr, read_mem) {
        Some(b) => b,
        None => {
            println!("[chain2] could not read PlayerTypeMap class def");
            return;
        }
    };

    let outer_entries_array =
        match dict_kv::entries_array_addr(offsets, &outer_class_bytes, ptm_addr, read_mem) {
            Some(a) => a,
            None => {
                println!("[chain2] PlayerTypeMap._entries not resolved or null");
                return;
            }
        };

    let outer_entries =
        match dict_kv::read_int_ptr_entries(offsets, outer_entries_array, read_mem) {
            Some(e) => e,
            None => {
                println!("[chain2] could not read PlayerTypeMap entries");
                return;
            }
        };

    println!("[chain2] PlayerTypeMap has {} seat(s)", outer_entries.len());

    for entry in outer_entries {
        let seat_id = entry.key;
        let inner_dict = entry.value;
        println!(
            "\n## seat={} (id={}) inner_dict=0x{:x}",
            seat_name(seat_id),
            seat_id,
            inner_dict
        );

        if inner_dict == 0 {
            println!("  inner dict is null — skipping");
            continue;
        }

        let inner_class_bytes = match read_class_def_for_object(inner_dict, read_mem) {
            Some(b) => b,
            None => {
                println!("  could not read inner dict class def");
                continue;
            }
        };

        let inner_class_name =
            read_class_name(&inner_class_bytes, read_mem).unwrap_or_else(|| "?".to_string());
        println!("  runtime class = '{}'", inner_class_name);

        let inner_entries_array =
            match dict_kv::entries_array_addr(offsets, &inner_class_bytes, inner_dict, read_mem)
            {
                Some(a) => a,
                None => {
                    println!("  inner dict ._entries not resolved");
                    continue;
                }
            };

        let inner_entries =
            match dict_kv::read_int_ptr_entries(offsets, inner_entries_array, read_mem) {
                Some(e) => e,
                None => {
                    println!("  could not read inner dict entries");
                    continue;
                }
            };

        println!("  {} zone(s):", inner_entries.len());

        for inner in &inner_entries {
            let zone_id = inner.key;
            let holder = inner.value;
            println!("\n  ─── zone_id={} holder=0x{:x}", zone_id, holder);

            if holder == 0 {
                println!("       holder is null — skipping");
                continue;
            }

            dump_holder(offsets, holder, read_mem);
        }
    }
}

fn dump_holder<F>(offsets: &MonoOffsets, holder_addr: u64, read_mem: &F)
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let class_bytes = match read_class_def_for_object(holder_addr, read_mem) {
        Some(b) => b,
        None => {
            println!("       could not read holder class def");
            return;
        }
    };

    let class_name = read_class_name(&class_bytes, read_mem).unwrap_or_else(|| "?".to_string());
    println!("       runtime class = '{}'", class_name);

    // Address of the class_addr is at vtable.klass — re-read for the dump_class signature.
    let vtable = read_mem(holder_addr, 8).and_then(|b| read_u64(&b)).unwrap_or(0);
    let class_addr = if vtable != 0 {
        read_mem(vtable, 8).and_then(|b| read_u64(&b)).unwrap_or(0)
    } else {
        0
    };

    if class_addr == 0 {
        println!("       could not resolve class_addr; skipping field dump");
        return;
    }

    println!("       fields:");
    dump_fields_summary(offsets, &class_bytes, read_mem);

    // For each instance field that names a List<T> or that resembles
    // a known card-bearing field, drill one level deeper.
    let fields_ptr = mono::class_fields_ptr(offsets, &class_bytes, 0).unwrap_or(0);
    let count = mono::class_def_field_count(offsets, &class_bytes, 0).unwrap_or(0) as usize;

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

        let (_attrs, is_static) = if type_ptr != 0 {
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

        if is_static || offset_val < 0 {
            continue;
        }

        // Drill into pointer-shaped fields whose names suggest card data.
        let interesting = name.contains("Card")
            || name.contains("Layout")
            || name.contains("Cdc")
            || name.contains("CDC")
            || name.contains("Region")
            || name.contains("Stack")
            || name.contains("Zone")
            || name == "_items"
            || name == "AllCards"
            || name == "<TopCard>k__BackingField";

        if !interesting {
            continue;
        }

        let slot_addr = holder_addr + offset_val as u64;
        let inner = read_mem(slot_addr, 8).and_then(|b| read_u64(&b)).unwrap_or(0);
        if inner == 0 {
            continue;
        }

        // Identify the inner object's runtime class.
        let inner_class_bytes = match read_class_def_for_object(inner, read_mem) {
            Some(b) => b,
            None => continue,
        };
        let inner_name =
            read_class_name(&inner_class_bytes, read_mem).unwrap_or_else(|| "?".to_string());

        println!(
            "         drill: {} (offset 0x{:x}) → 0x{:x} class='{}'",
            name, offset_val as u32, inner, inner_name
        );

        // For a curated set of "card-bearing" classes, dump their
        // field manifests too — the next walker module needs to know
        // what fields these structures expose.
        if is_deep_dive_class(&inner_name) {
            println!("           {} fields:", inner_name);
            dump_fields_summary(offsets, &inner_class_bytes, read_mem);
            // Recurse one more level for List<T> fields inside the
            // deep-dive class (e.g. BattlefieldRegionDefinition might
            // have a _stacks list whose elements are CardLayoutData).
            drill_lists_inside(offsets, inner, &inner_class_bytes, read_mem);
        }

        // If it's a List<T>, peek _size and _items.
        if inner_name.starts_with("List`1") {
            let size = field::find_by_name(offsets, &inner_class_bytes, 0, "_size", read_mem)
                .and_then(|f| read_mem(inner + f.offset as u64, 4))
                .and_then(|b| {
                    if b.len() < 4 {
                        None
                    } else {
                        Some(i32::from_le_bytes([b[0], b[1], b[2], b[3]]))
                    }
                })
                .unwrap_or(-1);
            let items_ptr = field::find_by_name(offsets, &inner_class_bytes, 0, "_items", read_mem)
                .and_then(|f| read_mem(inner + f.offset as u64, 8))
                .and_then(|b| read_u64(&b))
                .unwrap_or(0);

            println!(
                "           List._size={} _items=0x{:x}",
                size, items_ptr
            );

            // For a populated List<T>, peek the first element's runtime
            // class so we know what T is.
            if size > 0 && items_ptr != 0 {
                // Element 0 of the MonoArray<T> for a reference T lives
                // at items_ptr + 0x20.
                let elem_ptr = read_mem(items_ptr + 0x20, 8)
                    .and_then(|b| read_u64(&b))
                    .unwrap_or(0);

                if elem_ptr != 0 {
                    if let Some(eb) = read_class_def_for_object(elem_ptr, read_mem) {
                        let en = read_class_name(&eb, read_mem)
                            .unwrap_or_else(|| "?".to_string());
                        println!(
                            "           first element 0x{:x} class='{}'",
                            elem_ptr, en
                        );

                        // One level deeper: dump the element's fields too.
                        // This is where CardLayoutData → BaseCDC drill lives.
                        println!("           element fields:");
                        dump_fields_summary(offsets, &eb, read_mem);
                    } else {
                        // Element might be a value type (struct), not a
                        // reference. The bytes at items_ptr+0x20 are the
                        // first field of the struct, not a pointer.
                        println!(
                            "           first element bytes (val-type? first 8 bytes are 0x{:016x})",
                            elem_ptr
                        );
                    }
                }
            }
        }
    }
}

/// True when `class_name` is one of the curated MTGA classes whose
/// internal layout is needed to reach `BaseGrpId` / per-card data.
fn is_deep_dive_class(class_name: &str) -> bool {
    matches!(
        class_name,
        "DuelScene_CDC"
            | "BattlefieldRegionDefinition"
            | "BattlefieldLayout"
            | "BattlefieldRegion"
            | "CardLayout_Hand"
            | "CardLayout_HalfFan"
            | "CardLayout_General"
            | "MutationsLayout"
            | "BaseCDC"
            | "CardDataAdapter"
            | "CardPrintingData"
            | "CardInstanceData"
            | "CardLayoutData"
            | "BattlefieldStack"
    )
}

/// Inside `obj_addr`'s class blob, find every `List<>` instance field,
/// peek `_size` / `_items`, and if non-empty, dump the first element's
/// runtime class + fields. This is the "one more level" recursion used
/// after a `is_deep_dive_class` hit.
fn drill_lists_inside<F>(
    offsets: &MonoOffsets,
    obj_addr: u64,
    class_bytes: &[u8],
    read_mem: &F,
) where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
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

        let (_attrs, is_static) = if type_ptr != 0 {
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

        if is_static || offset_val < 0 {
            continue;
        }

        let slot = obj_addr + offset_val as u64;
        let inner = read_mem(slot, 8).and_then(|b| read_u64(&b)).unwrap_or(0);
        if inner == 0 {
            continue;
        }

        let inner_class_bytes = match read_class_def_for_object(inner, read_mem) {
            Some(b) => b,
            None => continue,
        };
        let inner_name =
            read_class_name(&inner_class_bytes, read_mem).unwrap_or_else(|| "?".to_string());

        // Only recurse on List<T> from this point — keep output bounded.
        if !inner_name.starts_with("List`1") && !inner_name.starts_with("Dictionary`2") {
            continue;
        }

        let size = field::find_by_name(offsets, &inner_class_bytes, 0, "_size", read_mem)
            .and_then(|f| read_mem(inner + f.offset as u64, 4))
            .and_then(|b| {
                if b.len() < 4 {
                    None
                } else {
                    Some(i32::from_le_bytes([b[0], b[1], b[2], b[3]]))
                }
            })
            .unwrap_or(-1);

        println!(
            "             nested {} ('{}'): size={}",
            inner_name, name, size
        );

        if !inner_name.starts_with("List`1") || size <= 0 {
            continue;
        }

        let items_ptr = field::find_by_name(offsets, &inner_class_bytes, 0, "_items", read_mem)
            .and_then(|f| read_mem(inner + f.offset as u64, 8))
            .and_then(|b| read_u64(&b))
            .unwrap_or(0);
        if items_ptr == 0 {
            continue;
        }

        let elem_ptr = read_mem(items_ptr + 0x20, 8)
            .and_then(|b| read_u64(&b))
            .unwrap_or(0);
        if elem_ptr == 0 {
            continue;
        }

        let elem_class_bytes = match read_class_def_for_object(elem_ptr, read_mem) {
            Some(b) => b,
            None => continue,
        };
        let elem_name = read_class_name(&elem_class_bytes, read_mem)
            .unwrap_or_else(|| "?".to_string());

        println!(
            "               first element 0x{:x} class='{}'",
            elem_ptr, elem_name
        );

        if is_deep_dive_class(&elem_name) {
            println!("               {} fields:", elem_name);
            dump_fields_summary(offsets, &elem_class_bytes, read_mem);
        }
    }
}

/// Compact form of `dump_class` — just instance fields, no header.
/// Walks up the parent class chain (max depth 4) so we see fields
/// declared on the base class too — `DuelScene_CDC` puts most of its
/// useful fields on its `BaseCDC` parent.
fn dump_fields_summary<F>(offsets: &MonoOffsets, class_bytes: &[u8], read_mem: &F)
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    dump_class_chain(offsets, class_bytes, 0, read_mem);
}

const MAX_PARENT_DEPTH: usize = 4;
const CLASS_PARENT_OFFSET: usize = 0x30;

fn dump_class_chain<F>(offsets: &MonoOffsets, class_bytes: &[u8], depth: usize, read_mem: &F)
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    if depth > MAX_PARENT_DEPTH {
        return;
    }

    let prefix = if depth == 0 { "this".to_string() } else { format!("parent^{}", depth) };
    let class_name =
        read_class_name(class_bytes, read_mem).unwrap_or_else(|| "?".to_string());
    println!("           [{}] class='{}'", prefix, class_name);

    dump_class_own_fields(offsets, class_bytes, read_mem);

    // Walk to parent.
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
    // Stop at System.Object — its name is "Object" and it has no
    // useful instance fields for our purposes.
    let parent_name =
        read_class_name(&parent_bytes, read_mem).unwrap_or_default();
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
            "           [{:2}] offset=0x{:04x} {} attrs=0x{:04x} name='{}'",
            i,
            offset_val as u32,
            if is_static { "STATIC  " } else { "instance" },
            attrs,
            name,
        );
    }
}

/// Fetch a `MonoClassDef` blob for whatever class an object's vtable points to.
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

// ─────────────────────────────────────────────────────────────────────
// helpers
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

/// Read a NUL-terminated UTF-8 string from `addr`, capped at `max` bytes.
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

/// Read `obj.vtable.klass` to get the runtime class pointer for an object.
///
/// `MonoObject.vtable` and `MonoVTable.klass` both live at offset 0 of
/// their structs.
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

/// Read a `MonoString` and decode its UTF-16 contents to a Rust `String`.
///
/// `MonoString` layout: `vtable(8) + sync(8) + length:i32 + chars[length]`
/// (UTF-16 LE).
fn read_mono_string<F>(addr: u64, read_mem: &F) -> Option<String>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    if addr == 0 {
        return None;
    }
    let header = read_mem(addr, 0x14)?;
    if header.len() < 0x14 {
        return None;
    }
    let length =
        i32::from_le_bytes([header[0x10], header[0x11], header[0x12], header[0x13]]).max(0) as usize;
    if length == 0 {
        return Some(String::new());
    }
    if length > 256 {
        // sanity guard
        return None;
    }
    let chars_addr = addr + 0x14;
    let chars_bytes = read_mem(chars_addr, length * 2)?;
    let utf16: Vec<u16> = chars_bytes
        .chunks_exact(2)
        .map(|c| u16::from_le_bytes([c[0], c[1]]))
        .collect();
    String::from_utf16(&utf16).ok()
}

/// Read `MonoClass.name` via offset 0x48.
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

/// Print a class header + every field's (name, offset, attrs) for a
/// `MonoClassDef`-laid-out class.
fn dump_class<F>(offsets: &MonoOffsets, class_addr: u64, class_bytes: &[u8], read_mem: &F)
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let name = read_class_name(class_bytes, read_mem).unwrap_or_else(|| "<unreadable>".to_string());
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
                println!("  [{i:3}] <read failed for field entry @ 0x{:x}>", entry_addr);
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
// pid resolution
// ─────────────────────────────────────────────────────────────────────

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
        let Some(name_str) = name.to_str() else { continue };
        let Ok(pid) = name_str.parse::<i32>() else { continue };

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
