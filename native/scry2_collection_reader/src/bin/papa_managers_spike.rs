//! Spike — drill three additional `PAPA._instance` backing fields and
//! dump their runtime classes' field manifests so we can identify
//! which fields hold the data needed to ship plans.md `reader+`
//! items.
//!
//! Targets:
//!   * `<AccountClient>k__BackingField`     (offset 0x00e0) — looking
//!     for screen name, wizards account UUID, creation timestamp.
//!   * `<InventoryManager>k__BackingField`  (offset 0x00e8) — pending
//!     packs by source, currency events.
//!   * `<CosmeticsProvider>k__BackingField` (offset 0x00f0) — pets,
//!     sleeves, avatars, emotes inventory.
//!
//! For each target we:
//!   1. Resolve PAPA._instance.<Field> by name.
//!   2. Print the singleton pointer + runtime class name.
//!   3. Dump every instance/static field on that class (parent chain
//!      too — managers commonly inherit from base classes).
//!   4. Probe known candidate names for primitive (string / i32 / bool)
//!      values and print decoded values when present.
//!
//! Capture stdout into spike22 FINDING.md.
//!
//! Usage:
//!   cargo run --bin papa-managers-spike --release [-- --pid=<n>]

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
const MAX_FIELDS_PER_CLASS: usize = 64;
const CLASS_PARENT_OFFSET: usize = 0x30;
const MAX_STRING_CHARS: usize = 128;

/// One probe target: PAPA backing-field name + candidate primitive
/// names to dereference once the singleton is resolved.
struct Target {
    /// Field name on PAPA — pass to `find_field_by_name`.
    papa_field: &'static str,
    /// Candidate field names to try after the runtime class is known.
    /// Each will be dereferenced and (if string-typed) decoded.
    string_probes: &'static [&'static str],
    int_probes: &'static [&'static str],
    bool_probes: &'static [&'static str],
    /// Sub-pointer field names whose target class should be drilled
    /// (manifest + pointer drill + string/int/bool probes). Used to
    /// follow `AccountClient → AccountInformation`,
    /// `CosmeticsProvider → CosmeticsClient`, etc.
    deep_drill: &'static [DeepDrill],
}

struct DeepDrill {
    sub_field: &'static str,
    string_probes: &'static [&'static str],
    int_probes: &'static [&'static str],
    bool_probes: &'static [&'static str],
}

const ACCOUNT_INFORMATION_PROBES: DeepDrill = DeepDrill {
    sub_field: "<AccountInformation>k__BackingField",
    string_probes: &[
        "_screenName",
        "ScreenName",
        "<ScreenName>k__BackingField",
        "_displayName",
        "DisplayName",
        "<DisplayName>k__BackingField",
        "_accountId",
        "AccountId",
        "<AccountId>k__BackingField",
        "_userId",
        "UserId",
        "<UserId>k__BackingField",
        "_personaId",
        "PersonaId",
        "<PersonaId>k__BackingField",
        "_wizardsAccountId",
        "<WizardsAccountId>k__BackingField",
        "_email",
        "_personaName",
        "_locale",
        "<Locale>k__BackingField",
        "_country",
        "<Country>k__BackingField",
        "_creationDate",
        "<CreationDate>k__BackingField",
        "_createdAt",
        "_createdDate",
        "_dateCreated",
        "<DateCreated>k__BackingField",
        "_birthDate",
        "<BirthDate>k__BackingField",
    ],
    int_probes: &[],
    bool_probes: &[
        "_isVerified",
        "<IsVerified>k__BackingField",
        "_isUnderage",
    ],
};

const COSMETICS_CLIENT_AVAILABLE_PROBES: DeepDrill = DeepDrill {
    sub_field: "_availableCosmetics",
    string_probes: &[],
    int_probes: &[],
    bool_probes: &[],
};

const COSMETICS_CLIENT_OWNED_PROBES: DeepDrill = DeepDrill {
    sub_field: "_playerOwnedCosmetics",
    string_probes: &[],
    int_probes: &[],
    bool_probes: &[],
};

const VANITY_SELECTIONS_PROBES: DeepDrill = DeepDrill {
    sub_field: "_vanitySelections",
    string_probes: &[],
    int_probes: &[],
    bool_probes: &[],
};

const TARGETS: &[Target] = &[
    Target {
        papa_field: "AccountClient",
        string_probes: &[],
        int_probes: &["<CurrentLoginState>k__BackingField"],
        bool_probes: &[],
        deep_drill: &[ACCOUNT_INFORMATION_PROBES],
    },
    Target {
        papa_field: "InventoryManager",
        string_probes: &[],
        int_probes: &[],
        bool_probes: &[],
        deep_drill: &[],
    },
    Target {
        papa_field: "CosmeticsProvider",
        string_probes: &[],
        int_probes: &[],
        bool_probes: &[],
        deep_drill: &[
            COSMETICS_CLIENT_AVAILABLE_PROBES,
            COSMETICS_CLIENT_OWNED_PROBES,
            VANITY_SELECTIONS_PROBES,
        ],
    },
];

fn main() -> ExitCode {
    let pid = match resolve_pid() {
        Ok(p) => p,
        Err(msg) => {
            eprintln!("[spike] could not resolve MTGA pid: {msg}");
            return ExitCode::from(2);
        }
    };
    eprintln!("[spike] MTGA pid = {pid}");
    println!("# Spike 22 — PAPA managers field manifest probe");
    println!("[spike] MTGA pid = {pid}");

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
    println!(
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
    println!("[spike] root_domain = 0x{:x}", domain_addr);

    let images = match image_lookup::list_all_images(&offsets, domain_addr, read_mem) {
        Some(imgs) => imgs,
        None => {
            eprintln!("[spike] could not enumerate images");
            return ExitCode::from(2);
        }
    };
    println!("[spike] found {} loaded images", images.len());

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
                println!("[spike] PAPA._instance is NULL — log in to MTGA and retry");
                return ExitCode::from(1);
            }
        };
    println!(
        "[spike] PAPA._instance singleton = 0x{:x}",
        papa_singleton_addr
    );

    for target in TARGETS {
        println!(
            "\n# ─────────────────────────────────────────────────────────"
        );
        println!("# Target: PAPA._instance.{}", target.papa_field);
        probe_target(
            &offsets,
            target,
            papa_singleton_addr,
            &papa_bytes,
            &read_mem,
        );
    }

    println!("\n[spike] done.");
    ExitCode::SUCCESS
}

fn probe_target<F>(
    offsets: &MonoOffsets,
    target: &Target,
    papa_singleton_addr: u64,
    papa_bytes: &[u8],
    read_mem: &F,
) where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let f = match field::find_field_by_name(offsets, papa_bytes, target.papa_field, read_mem) {
        Some(f) if !f.is_static => f,
        Some(f) => {
            println!(
                "  → resolved as STATIC (offset 0x{:x}) — unexpected; skipping",
                f.offset
            );
            return;
        }
        None => {
            println!("  → field '{}' NOT FOUND on PAPA", target.papa_field);
            return;
        }
    };
    println!(
        "  → resolved '{}' (offset 0x{:04x}, instance)",
        f.name_found, f.offset as u32
    );

    let mgr_addr = match read_mem(papa_singleton_addr + f.offset as u64, 8)
        .and_then(|b| read_u64(&b))
    {
        Some(0) => {
            println!("  → singleton pointer is NULL (manager not yet constructed)");
            return;
        }
        Some(p) => p,
        None => {
            println!("  → could not read singleton pointer");
            return;
        }
    };
    println!("  singleton = 0x{:x}", mgr_addr);

    let mgr_class = match read_object_class(mgr_addr, read_mem) {
        Some(c) => c,
        None => {
            println!("  → could not read singleton runtime class");
            return;
        }
    };
    let mgr_class_bytes = match read_mem(mgr_class, CLASS_DEF_BLOB_LEN) {
        Some(b) => b,
        None => {
            println!("  → could not read singleton class def");
            return;
        }
    };
    let class_name =
        read_class_name(&mgr_class_bytes, read_mem).unwrap_or_else(|| "<unreadable>".to_string());
    println!(
        "  runtime class = '{}' (class addr 0x{:x})",
        class_name, mgr_class
    );

    println!("\n  ── full field manifest (this + parent chain) ──");
    dump_class_chain(offsets, &mgr_class_bytes, 0, read_mem);

    println!("\n  ── pointer drill (instance pointer fields, depth 1) ──");
    drill_pointer_fields(offsets, mgr_addr, &mgr_class_bytes, read_mem);

    if !target.string_probes.is_empty() {
        println!("\n  ── string probes ──");
        for name in target.string_probes {
            probe_string(offsets, mgr_addr, &mgr_class_bytes, name, read_mem);
        }
    }
    if !target.int_probes.is_empty() {
        println!("\n  ── i32 probes ──");
        for name in target.int_probes {
            probe_i32(offsets, mgr_addr, &mgr_class_bytes, name, read_mem);
        }
    }
    if !target.bool_probes.is_empty() {
        println!("\n  ── bool probes ──");
        for name in target.bool_probes {
            probe_bool(offsets, mgr_addr, &mgr_class_bytes, name, read_mem);
        }
    }

    for drill in target.deep_drill {
        println!(
            "\n  # ── deep drill: '{}' ── ──────────────────────────",
            drill.sub_field
        );
        deep_drill_one(offsets, mgr_addr, &mgr_class_bytes, drill, read_mem);
    }
}

fn deep_drill_one<F>(
    offsets: &MonoOffsets,
    parent_addr: u64,
    parent_class_bytes: &[u8],
    drill: &DeepDrill,
    read_mem: &F,
) where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let Some(f) =
        field::find_field_by_name_in_chain(offsets, parent_class_bytes, drill.sub_field, read_mem)
    else {
        println!("    sub-field '{}' NOT FOUND on parent", drill.sub_field);
        return;
    };
    if f.is_static {
        println!("    sub-field '{}' is STATIC — unexpected", f.name_found);
        return;
    }
    let Some(sub_addr) = read_mem(parent_addr + f.offset as u64, 8).and_then(|b| read_u64(&b))
    else {
        println!("    could not read sub-field '{}' pointer", f.name_found);
        return;
    };
    if sub_addr == 0 {
        println!("    sub-field '{}' (offset 0x{:04x}) → NULL", f.name_found, f.offset as u32);
        return;
    }
    println!(
        "    sub-field '{}' (offset 0x{:04x}) → 0x{:x}",
        f.name_found, f.offset as u32, sub_addr
    );
    let Some(sub_class) = read_object_class(sub_addr, read_mem) else {
        println!("    could not resolve sub-object runtime class");
        return;
    };
    let Some(sub_class_bytes) = read_mem(sub_class, CLASS_DEF_BLOB_LEN) else {
        println!("    could not read sub-object class def");
        return;
    };
    let class_name =
        read_class_name(&sub_class_bytes, read_mem).unwrap_or_else(|| "<unreadable>".to_string());
    println!("    runtime class = '{}' (class addr 0x{:x})", class_name, sub_class);

    println!("\n    ── full field manifest (this + parent chain) ──");
    dump_class_chain(offsets, &sub_class_bytes, 0, read_mem);

    println!("\n    ── pointer drill (instance pointer fields, depth 1) ──");
    drill_pointer_fields(offsets, sub_addr, &sub_class_bytes, read_mem);

    if !drill.string_probes.is_empty() {
        println!("\n    ── string probes ──");
        for name in drill.string_probes {
            probe_string(offsets, sub_addr, &sub_class_bytes, name, read_mem);
        }
    }
    if !drill.int_probes.is_empty() {
        println!("\n    ── i32 probes ──");
        for name in drill.int_probes {
            probe_i32(offsets, sub_addr, &sub_class_bytes, name, read_mem);
        }
    }
    if !drill.bool_probes.is_empty() {
        println!("\n    ── bool probes ──");
        for name in drill.bool_probes {
            probe_bool(offsets, sub_addr, &sub_class_bytes, name, read_mem);
        }
    }
}

fn probe_string<F>(
    offsets: &MonoOffsets,
    obj_addr: u64,
    class_bytes: &[u8],
    name: &str,
    read_mem: &F,
) where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let Some(f) = field::find_field_by_name_in_chain(offsets, class_bytes, name, read_mem) else {
        return;
    };
    if f.is_static {
        return;
    }
    let str_addr = match read_mem(obj_addr + f.offset as u64, 8).and_then(|b| read_u64(&b)) {
        Some(p) => p,
        None => return,
    };
    if str_addr == 0 {
        println!(
            "  '{}' (offset 0x{:04x}) → NULL",
            f.name_found, f.offset as u32
        );
        return;
    }
    match mono::read_mono_string(str_addr, MAX_STRING_CHARS, read_mem) {
        Some(s) => println!(
            "  '{}' (offset 0x{:04x}) = {:?}",
            f.name_found, f.offset as u32, s
        ),
        None => println!(
            "  '{}' (offset 0x{:04x}) = <not a MonoString or unreadable> (ptr 0x{:x})",
            f.name_found, f.offset as u32, str_addr
        ),
    }
}

fn probe_i32<F>(
    offsets: &MonoOffsets,
    obj_addr: u64,
    class_bytes: &[u8],
    name: &str,
    read_mem: &F,
) where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let Some(f) = field::find_field_by_name_in_chain(offsets, class_bytes, name, read_mem) else {
        return;
    };
    if f.is_static {
        return;
    }
    let Some(b) = read_mem(obj_addr + f.offset as u64, 4) else {
        return;
    };
    if b.len() < 4 {
        return;
    }
    let v = i32::from_le_bytes([b[0], b[1], b[2], b[3]]);
    println!(
        "  '{}' (offset 0x{:04x}) = i32:{}",
        f.name_found, f.offset as u32, v
    );
}

fn probe_bool<F>(
    offsets: &MonoOffsets,
    obj_addr: u64,
    class_bytes: &[u8],
    name: &str,
    read_mem: &F,
) where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let Some(f) = field::find_field_by_name_in_chain(offsets, class_bytes, name, read_mem) else {
        return;
    };
    if f.is_static {
        return;
    }
    let Some(b) = read_mem(obj_addr + f.offset as u64, 1) else {
        return;
    };
    if b.is_empty() {
        return;
    }
    println!(
        "  '{}' (offset 0x{:04x}) = bool:{}",
        f.name_found,
        f.offset as u32,
        b[0] != 0
    );
}

/// Dereference each instance pointer field one level: read the
/// pointer, read the runtime class, print the class name. Spots
/// nested manager singletons (e.g. AccountClient holds a
/// `WizardsAccountsClient` that holds the actual identity).
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
        // Heuristic: only follow non-trivial offsets and skip raw
        // primitives (offset_val < 0x10 means object header).
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

// ─────────────────────────── helpers (lifted) ───────────────────────────

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
