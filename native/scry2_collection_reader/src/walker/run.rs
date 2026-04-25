//! Top-level walker orchestrator.
//!
//! Stitches every walker primitive into one entry point that the NIF
//! shell can call:
//!
//! ```text
//! list_maps  → locate `mono-2.0-bdwgc.dll` + stitch its sections
//!            → domain::find_root_domain
//!            → image_lookup × {Core, Assembly-CSharp, mscorlib}
//!            → class_lookup × {PAPA, InventoryManager,
//!                              InventoryServiceWrapper,
//!                              ClientPlayerInventory, Dictionary`2}
//!            → read MonoClassDef blobs for each class
//!            → chain::from_papa_class
//!            → WalkResult { entries, inventory }
//! ```
//!
//! The function takes a pre-fetched `maps` slice and a
//! `read_mem(addr, len) -> Option<Vec<u8>>` closure rather than calling
//! into `crate::platform` directly. This keeps the orchestrator pure
//! (no /proc, no syscalls) so unit tests can drive it with a
//! `FakeMem`-style fixture.

use super::chain;
use super::class_lookup;
use super::dict::DictEntry;
use super::domain;
use super::image_lookup;
use super::inventory::InventoryValues;
use super::mono::MonoOffsets;

/// Bytes to read for each `MonoClassDef` blob the walker consumes.
/// Must cover:
/// - `MonoClass.runtime_info` @ `0xd0`
/// - `MonoClass.vtable_size`  @ `0x5c`
/// - `MonoClass.fields`       @ `0x98`
/// - `MonoClassDef.field_count` @ `0x100`
///
/// 0x110 is the smallest power-of-16 size that covers all four.
pub const CLASS_DEF_BLOB_LEN: usize = 0x110;

/// Filename substring that identifies MTGA's Mono runtime DLL on
/// every platform. `/proc/<pid>/maps` paths can be Wine-style with
/// drive letters and arbitrary case; matching is case-insensitive
/// against the basename portion.
pub const MONO_DLL_NEEDLE: &str = "mono-2.0-bdwgc.dll";

/// Failure modes for [`walk_collection`]. Variants intentionally
/// carry the **specific** thing that wasn't found so the Elixir
/// `Scry2.Collection.Reader` (per ADR-034) can route loudly.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WalkError {
    /// `mono-2.0-bdwgc.dll` is not loaded in the target process.
    MonoDllNotFound,
    /// Found the DLL in `/proc/<pid>/maps` but at least one of its
    /// mapped regions can't be read. Often means the process exited
    /// between the maps snapshot and the reads.
    MonoDllReadFailed,
    /// `mono_get_root_domain` couldn't be decoded. Either the symbol
    /// isn't exported, the prologue doesn't match the expected
    /// `mov rax,[rip+disp32]; ret` shape, or the static slot is null.
    RootDomainNotFound,
    /// A required managed assembly couldn't be found in the root
    /// domain's `domain_assemblies` list.
    AssemblyNotFound(&'static str),
    /// A required managed class couldn't be found in any of its
    /// candidate images' `class_cache` tables.
    ClassNotFound(&'static str),
    /// Found the class but couldn't read its `MonoClassDef` bytes.
    ClassReadFailed(&'static str),
    /// Reached the chain orchestrator but at least one of the inner
    /// pointer hops failed (null field, unresolved name, etc.).
    /// Reported as a single variant since the inner walker doesn't
    /// distinguish — see [`chain::from_papa_class`].
    ChainFailed,
}

/// Full walk result returned by [`walk_collection`]. Wraps
/// [`chain::WalkResult`] and adds the disk-sourced
/// `mtga_build_hint`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Snapshot {
    /// Used entries from the `Cards` dictionary.
    pub entries: Vec<DictEntry>,
    /// Wildcards / currencies / vault progress.
    pub inventory: InventoryValues,
    /// MTGA build GUID from `boot.config`, or `None` if the file
    /// couldn't be located or parsed. Useful as a sanity check on
    /// top of walker output: when the GUID changes between runs the
    /// walker offsets may have shifted.
    pub mtga_build_hint: Option<String>,
}

/// One row in `/proc/<pid>/maps`-style output, in the shape
/// `crate::platform::list_maps` already returns.
pub type MapEntry = (u64, u64, String, Option<String>);

/// Run the full walker against a target process.
///
/// `maps` is the output of `list_maps(pid)`. `read_mem(addr, len)`
/// reads `len` bytes from the target process at remote address
/// `addr`, returning `None` on any failure. `build_hint` is invoked
/// once after the chain succeeds — split out as a closure so unit
/// tests stay disk-free; the NIF wrapper passes a closure that
/// composes [`super::build_hint::find_mtga_root`] +
/// [`super::build_hint::read_build_guid`].
pub fn walk_collection<F, B>(
    maps: &[MapEntry],
    read_mem: F,
    build_hint: B,
) -> Result<Snapshot, WalkError>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
    B: FnOnce() -> Option<String>,
{
    let offsets = MonoOffsets::mtga_default();

    let (mono_base, mono_bytes) =
        read_mono_image(maps, &read_mem).ok_or(WalkError::MonoDllReadFailed)?;
    if mono_bytes.is_empty() {
        return Err(WalkError::MonoDllNotFound);
    }

    let domain_addr = domain::find_root_domain(&mono_bytes, mono_base, read_mem)
        .ok_or(WalkError::RootDomainNotFound)?;

    let core_image = image_lookup::find_by_assembly_name(&offsets, domain_addr, "Core", read_mem)
        .ok_or(WalkError::AssemblyNotFound("Core"))?;
    let csharp_image =
        image_lookup::find_by_assembly_name(&offsets, domain_addr, "Assembly-CSharp", read_mem)
            .ok_or(WalkError::AssemblyNotFound("Assembly-CSharp"))?;
    let mscorlib_image =
        image_lookup::find_by_assembly_name(&offsets, domain_addr, "mscorlib", read_mem)
            .ok_or(WalkError::AssemblyNotFound("mscorlib"))?;

    // PAPA can live in either Core or Assembly-CSharp depending on
    // build. Try Core first (the spike-7 finding) and fall back.
    let papa_addr = find_class_in_images(&offsets, &[core_image, csharp_image], "PAPA", read_mem)
        .ok_or(WalkError::ClassNotFound("PAPA"))?;

    let inventory_manager_addr = find_class_in_images(
        &offsets,
        &[csharp_image, core_image],
        "InventoryManager",
        read_mem,
    )
    .ok_or(WalkError::ClassNotFound("InventoryManager"))?;

    let service_wrapper_addr = find_class_in_images(
        &offsets,
        &[csharp_image, core_image],
        "InventoryServiceWrapper",
        read_mem,
    )
    .ok_or(WalkError::ClassNotFound("InventoryServiceWrapper"))?;

    let inventory_addr = find_class_in_images(
        &offsets,
        &[csharp_image, core_image],
        "ClientPlayerInventory",
        read_mem,
    )
    .ok_or(WalkError::ClassNotFound("ClientPlayerInventory"))?;

    // Dictionary`2 lives in mscorlib; Core also imports it but the
    // open-generic class definition only exists once.
    let dict_addr = find_class_in_images(&offsets, &[mscorlib_image], "Dictionary`2", read_mem)
        .ok_or(WalkError::ClassNotFound("Dictionary`2"))?;

    let papa_bytes =
        read_mem(papa_addr, CLASS_DEF_BLOB_LEN).ok_or(WalkError::ClassReadFailed("PAPA"))?;
    let inventory_manager_bytes = read_mem(inventory_manager_addr, CLASS_DEF_BLOB_LEN)
        .ok_or(WalkError::ClassReadFailed("InventoryManager"))?;
    let service_wrapper_bytes = read_mem(service_wrapper_addr, CLASS_DEF_BLOB_LEN)
        .ok_or(WalkError::ClassReadFailed("InventoryServiceWrapper"))?;
    let inventory_bytes = read_mem(inventory_addr, CLASS_DEF_BLOB_LEN)
        .ok_or(WalkError::ClassReadFailed("ClientPlayerInventory"))?;
    let dict_bytes = read_mem(dict_addr, CLASS_DEF_BLOB_LEN)
        .ok_or(WalkError::ClassReadFailed("Dictionary`2"))?;

    let walk = chain::from_papa_class(
        &offsets,
        papa_addr,
        domain_addr,
        &papa_bytes,
        &inventory_manager_bytes,
        &service_wrapper_bytes,
        &dict_bytes,
        &inventory_bytes,
        read_mem,
    )
    .ok_or(WalkError::ChainFailed)?;

    Ok(Snapshot {
        entries: walk.entries,
        inventory: walk.inventory,
        mtga_build_hint: build_hint(),
    })
}

/// Locate the mono DLL in `maps`, stitch all its mapped sections
/// into one contiguous buffer indexed by RVA, and return
/// `(base, bytes)`.
///
/// Returns `None` if the DLL isn't loaded *or* every mapped region
/// of it fails to read. A partial read (some sections succeed,
/// others fail) yields `Some((base, bytes))` with the failed regions
/// zero-filled; PE parsing will still find headers and exports as
/// long as those sections come back.
///
/// Implementation note: `/proc/<pid>/maps` lists each PE section as
/// a separate line because the loader gives each section its own
/// permissions. We compute the image's base as the lowest start
/// address among matching entries and the image's span as
/// `max(end) - min(start)`.
pub fn read_mono_image<F>(maps: &[MapEntry], read_mem: &F) -> Option<(u64, Vec<u8>)>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let dll_maps: Vec<&MapEntry> = maps
        .iter()
        .filter(|(_, _, _, path)| path_matches_mono_dll(path.as_deref()))
        .collect();
    if dll_maps.is_empty() {
        return None;
    }

    let base = dll_maps.iter().map(|(s, _, _, _)| *s).min()?;
    let max_end = dll_maps.iter().map(|(_, e, _, _)| *e).max()?;
    let span = (max_end - base) as usize;
    let mut buf = vec![0u8; span];

    let mut any_read = false;
    for (start, end, _, _) in &dll_maps {
        let off = (start - base) as usize;
        let len = (end - start) as usize;
        if let Some(bytes) = read_mem(*start, len) {
            let copy_len = bytes.len().min(len);
            buf[off..off + copy_len].copy_from_slice(&bytes[..copy_len]);
            any_read = true;
        }
    }
    if !any_read {
        return None;
    }
    Some((base, buf))
}

/// Case-insensitive match on the path's basename (or, when the
/// loader gives us a Wine-style `\` path, the trailing component
/// after `\` or `/`).
fn path_matches_mono_dll(path: Option<&str>) -> bool {
    let path = match path {
        Some(p) => p,
        None => return false,
    };
    let basename = path.rsplit(['/', '\\']).next().unwrap_or(path);
    basename.eq_ignore_ascii_case(MONO_DLL_NEEDLE)
}

/// Try `class_lookup::find_by_name` against each image in turn,
/// returning the first hit.
fn find_class_in_images<F>(
    offsets: &MonoOffsets,
    images: &[u64],
    target: &str,
    read_mem: F,
) -> Option<u64>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    for image in images {
        if let Some(addr) = class_lookup::find_by_name(offsets, *image, target, read_mem) {
            return Some(addr);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::walker::dict::DictEntry;
    use crate::walker::mono::POINTER_SIZE;

    /// FakeMem fixture identical in shape to the one used in
    /// `field`/`image_lookup`/`class_lookup`/`chain` tests.
    #[derive(Default)]
    struct FakeMem {
        blocks: Vec<(u64, Vec<u8>)>,
    }

    impl FakeMem {
        fn add(&mut self, addr: u64, bytes: Vec<u8>) {
            self.blocks.push((addr, bytes));
        }
        fn read(&self, addr: u64, len: usize) -> Option<Vec<u8>> {
            for (base, data) in &self.blocks {
                if addr >= *base {
                    let off = (addr - *base) as usize;
                    if off < data.len() {
                        let end = off.saturating_add(len).min(data.len());
                        return Some(data[off..end].to_vec());
                    }
                }
            }
            None
        }
    }

    #[test]
    fn path_match_accepts_unix_paths() {
        assert!(path_matches_mono_dll(Some(
            "/home/x/.steam/.../EmbedRuntime/mono-2.0-bdwgc.dll"
        )));
    }

    #[test]
    fn path_match_accepts_wine_style_paths() {
        assert!(path_matches_mono_dll(Some(
            r"Z:\Steam\steamapps\common\MTGA\MonoBleedingEdge\EmbedRuntime\mono-2.0-bdwgc.dll"
        )));
    }

    #[test]
    fn path_match_is_case_insensitive() {
        assert!(path_matches_mono_dll(Some("/path/to/Mono-2.0-BDWGC.DLL")));
    }

    #[test]
    fn path_match_rejects_unrelated_dlls() {
        assert!(!path_matches_mono_dll(Some("/path/to/some-other.dll")));
        assert!(!path_matches_mono_dll(Some("/path/to/mono.dll")));
        assert!(!path_matches_mono_dll(None));
    }

    #[test]
    fn read_mono_image_stitches_three_section_layout() -> Result<(), String> {
        // Mimic /proc/<pid>/maps: three rwxp/r-p/rw-p regions for
        // the same mono DLL, each at its own RVA.
        let base: u64 = 0x180000000;
        let maps: Vec<MapEntry> = vec![
            (
                base,
                base + 0x1000,
                "r-xp".to_string(),
                Some("/abs/mono-2.0-bdwgc.dll".to_string()),
            ),
            (
                base + 0x2000,
                base + 0x2800,
                "r--p".to_string(),
                Some("/abs/mono-2.0-bdwgc.dll".to_string()),
            ),
            (
                base + 0x3000,
                base + 0x3100,
                "rw-p".to_string(),
                Some("/abs/mono-2.0-bdwgc.dll".to_string()),
            ),
            // unrelated
            (
                0x10_0000,
                0x11_0000,
                "r--p".to_string(),
                Some("/lib/other.so".to_string()),
            ),
        ];
        let mut mem = FakeMem::default();
        // Section 0 first byte = 0x11; section 1 first = 0x22; section 2 first = 0x33.
        mem.add(base, {
            let mut v = vec![0u8; 0x1000];
            v[0] = 0x11;
            v
        });
        mem.add(base + 0x2000, {
            let mut v = vec![0u8; 0x800];
            v[0] = 0x22;
            v
        });
        mem.add(base + 0x3000, {
            let mut v = vec![0u8; 0x100];
            v[0] = 0x33;
            v
        });

        let (got_base, bytes) =
            read_mono_image(&maps, &|a, l| mem.read(a, l)).ok_or("stitch should succeed")?;
        assert_eq!(got_base, base);
        // Span is from the lowest start to the highest end:
        assert_eq!(bytes.len(), 0x3100);
        // RVA 0 → first byte of section 0
        assert_eq!(bytes[0], 0x11);
        // RVA 0x2000 → first byte of section 1
        assert_eq!(bytes[0x2000], 0x22);
        // RVA 0x3000 → first byte of section 2
        assert_eq!(bytes[0x3000], 0x33);
        // RVA 0x1000 (unmapped gap) → zero-filled
        assert_eq!(bytes[0x1000], 0);
        Ok(())
    }

    #[test]
    fn read_mono_image_returns_none_when_dll_missing() {
        let maps: Vec<MapEntry> = vec![(
            0x1000,
            0x2000,
            "r--p".to_string(),
            Some("/lib/unrelated.so".to_string()),
        )];
        let mem = FakeMem::default();
        assert!(read_mono_image(&maps, &|a, l| mem.read(a, l)).is_none());
    }

    #[test]
    fn read_mono_image_returns_none_when_every_region_unreadable() {
        // DLL is in the maps but read_mem misses every region.
        let base: u64 = 0x180000000;
        let maps: Vec<MapEntry> = vec![(
            base,
            base + 0x1000,
            "r-xp".to_string(),
            Some("/abs/mono-2.0-bdwgc.dll".to_string()),
        )];
        let mem = FakeMem::default();
        assert!(read_mono_image(&maps, &|a, l| mem.read(a, l)).is_none());
    }

    #[test]
    fn walk_collection_returns_dll_not_found_when_mono_missing() {
        let maps: Vec<MapEntry> = vec![];
        let mem = FakeMem::default();
        assert_eq!(
            walk_collection(&maps, |a, l| mem.read(a, l), || None),
            Err(WalkError::MonoDllReadFailed)
        );
    }

    // ============================================================
    // End-to-end orchestration test.
    //
    // Builds a minimal in-memory simulation of the full chain:
    //   - A "mono DLL" with mono_get_root_domain → static MonoDomain *
    //   - MonoDomain with domain_assemblies GSList → {Core, Assembly-CSharp, mscorlib}
    //   - Each MonoImage with class_cache → 1 class per image at a known address
    //   - PAPA static _instance → singleton → InventoryManager → ServiceWrapper
    //   - ServiceWrapper → Dictionary<int,int> + ClientPlayerInventory
    //   - Final WalkResult assertion.
    //
    // This is the **integration test** that proves walker::run wires
    // every primitive together correctly; the inner pieces are unit-
    // tested in their own modules.
    // ============================================================

    /// PE layout knobs (duplicated from `domain` tests so this
    /// integration test stands alone — same values).
    const PE_TOTAL_SIZE: usize = 0x2000;
    const E_LFANEW: usize = 0x80;
    const COFF_HEADER_LEN: usize = 20;
    const OPT_OFF: usize = E_LFANEW + 4 + COFF_HEADER_LEN;
    const EXPORT_DIR_RVA: usize = 0x200;
    const EXPORT_DIR_SIZE: u32 = 0x80;
    const NAMES_RVA: usize = 0x300;
    const ORDS_RVA: usize = 0x340;
    const FUNCS_RVA: usize = 0x380;
    const STRINGS_RVA: usize = 0x400;
    const FN_RVA: u32 = 0x800;
    const DOS_MAGIC: u16 = 0x5a4d;
    const PE_SIGNATURE: u32 = 0x0000_4550;
    const PE32_PLUS_MAGIC: u16 = 0x20b;
    const OPT_NUMBER_OF_RVA_AND_SIZES_OFFSET: usize = 108;
    const OPT_DATA_DIR_OFFSET: usize = 112;

    fn build_mono_dll(static_ptr_rva: u32) -> Vec<u8> {
        let mut bytes = vec![0u8; PE_TOTAL_SIZE];
        bytes[0..2].copy_from_slice(&DOS_MAGIC.to_le_bytes());
        bytes[0x3c..0x40].copy_from_slice(&(E_LFANEW as u32).to_le_bytes());
        bytes[E_LFANEW..E_LFANEW + 4].copy_from_slice(&PE_SIGNATURE.to_le_bytes());
        bytes[OPT_OFF..OPT_OFF + 2].copy_from_slice(&PE32_PLUS_MAGIC.to_le_bytes());
        bytes[OPT_OFF + OPT_NUMBER_OF_RVA_AND_SIZES_OFFSET
            ..OPT_OFF + OPT_NUMBER_OF_RVA_AND_SIZES_OFFSET + 4]
            .copy_from_slice(&16u32.to_le_bytes());
        bytes[OPT_OFF + OPT_DATA_DIR_OFFSET..OPT_OFF + OPT_DATA_DIR_OFFSET + 4]
            .copy_from_slice(&(EXPORT_DIR_RVA as u32).to_le_bytes());
        bytes[OPT_OFF + OPT_DATA_DIR_OFFSET + 4..OPT_OFF + OPT_DATA_DIR_OFFSET + 8]
            .copy_from_slice(&EXPORT_DIR_SIZE.to_le_bytes());

        bytes[EXPORT_DIR_RVA + 20..EXPORT_DIR_RVA + 24].copy_from_slice(&1u32.to_le_bytes());
        bytes[EXPORT_DIR_RVA + 24..EXPORT_DIR_RVA + 28].copy_from_slice(&1u32.to_le_bytes());
        bytes[EXPORT_DIR_RVA + 28..EXPORT_DIR_RVA + 32]
            .copy_from_slice(&(FUNCS_RVA as u32).to_le_bytes());
        bytes[EXPORT_DIR_RVA + 32..EXPORT_DIR_RVA + 36]
            .copy_from_slice(&(NAMES_RVA as u32).to_le_bytes());
        bytes[EXPORT_DIR_RVA + 36..EXPORT_DIR_RVA + 40]
            .copy_from_slice(&(ORDS_RVA as u32).to_le_bytes());
        bytes[NAMES_RVA..NAMES_RVA + 4].copy_from_slice(&(STRINGS_RVA as u32).to_le_bytes());
        bytes[ORDS_RVA..ORDS_RVA + 2].copy_from_slice(&0u16.to_le_bytes());
        bytes[FUNCS_RVA..FUNCS_RVA + 4].copy_from_slice(&FN_RVA.to_le_bytes());

        let name = b"mono_get_root_domain";
        bytes[STRINGS_RVA..STRINGS_RVA + name.len()].copy_from_slice(name);
        bytes[STRINGS_RVA + name.len()] = 0;

        let rip_after_mov = FN_RVA as i64 + 7;
        let disp32 = (static_ptr_rva as i64 - rip_after_mov) as i32;
        let dbytes = disp32.to_le_bytes();
        let off = FN_RVA as usize;
        bytes[off] = 0x48;
        bytes[off + 1] = 0x8b;
        bytes[off + 2] = 0x05;
        bytes[off + 3] = dbytes[0];
        bytes[off + 4] = dbytes[1];
        bytes[off + 5] = dbytes[2];
        bytes[off + 6] = dbytes[3];
        bytes[off + 7] = 0xc3;
        bytes
    }

    /// Write a 32-byte MonoClassField entry at the given address.
    fn write_field(
        mem: &mut FakeMem,
        fields_array_addr: u64,
        index: u64,
        name_addr: u64,
        type_addr: u64,
        offset: i32,
        is_static: bool,
    ) {
        let o = MonoOffsets::mtga_default();
        let entry_addr = fields_array_addr + index * 32;
        let mut entry = vec![0u8; 32];
        entry[o.field_type..o.field_type + 8].copy_from_slice(&type_addr.to_le_bytes());
        entry[o.field_name..o.field_name + 8].copy_from_slice(&name_addr.to_le_bytes());
        entry[o.field_offset..o.field_offset + 4].copy_from_slice(&(offset as u32).to_le_bytes());
        mem.add(entry_addr, entry);

        let mut tbuf = vec![0u8; 16];
        let attrs: u32 = if is_static { 0x10 } else { 0 };
        tbuf[8..12].copy_from_slice(&attrs.to_le_bytes());
        mem.add(type_addr, tbuf);
    }

    fn write_cstring(mem: &mut FakeMem, addr: u64, s: &str) {
        let mut v = s.as_bytes().to_vec();
        v.push(0);
        mem.add(addr, v);
    }

    /// Write a `MonoClassDef` blob carrying `MonoClass.fields`,
    /// `MonoClass.runtime_info`, `MonoClass.vtable_size`,
    /// `MonoClass.name`, and `MonoClassDef.field_count`.
    #[allow(clippy::too_many_arguments)]
    fn write_class_def(
        mem: &mut FakeMem,
        class_addr: u64,
        fields_array_addr: u64,
        field_count: u32,
        runtime_info: u64,
        vtable_size: i32,
        name_addr: u64,
    ) {
        let o = MonoOffsets::mtga_default();
        let mut buf = vec![0u8; CLASS_DEF_BLOB_LEN];
        buf[o.class_fields..o.class_fields + 8].copy_from_slice(&fields_array_addr.to_le_bytes());
        buf[o.class_def_field_count..o.class_def_field_count + 4]
            .copy_from_slice(&field_count.to_le_bytes());
        buf[o.class_runtime_info..o.class_runtime_info + 8]
            .copy_from_slice(&runtime_info.to_le_bytes());
        buf[o.class_vtable_size..o.class_vtable_size + 4]
            .copy_from_slice(&(vtable_size as u32).to_le_bytes());
        buf[o.class_name..o.class_name + 8].copy_from_slice(&name_addr.to_le_bytes());
        mem.add(class_addr, buf);
    }

    /// Build a single-bucket `MonoImage.class_cache` containing one
    /// class. Writes the image bytes (with `class_cache` embedded at
    /// offset `image_class_cache`), the bucket-pointer array, and
    /// the class blob's `next_class_cache = 0` slot.
    fn install_image_with_one_class(
        mem: &mut FakeMem,
        image_addr: u64,
        bucket_array_addr: u64,
        class_addr: u64,
    ) {
        let o = MonoOffsets::mtga_default();
        // Image: write the class_cache header (size=1, num_entries=1, table=bucket_array)
        let mut image = vec![0u8; o.image_class_cache + o.hash_table_table + POINTER_SIZE];
        let cc = o.image_class_cache;
        image[cc + o.hash_table_size..cc + o.hash_table_size + 4]
            .copy_from_slice(&1u32.to_le_bytes());
        image[cc + o.hash_table_num_entries..cc + o.hash_table_num_entries + 4]
            .copy_from_slice(&1u32.to_le_bytes());
        image[cc + o.hash_table_table..cc + o.hash_table_table + 8]
            .copy_from_slice(&bucket_array_addr.to_le_bytes());
        mem.add(image_addr, image);

        // Bucket array: one slot pointing at the class.
        mem.add(bucket_array_addr, class_addr.to_le_bytes().to_vec());
    }

    #[test]
    fn walk_collection_end_to_end() -> Result<(), String> {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();

        // ---- 1. Mono DLL + maps + static MonoDomain pointer
        let mono_base: u64 = 0x180000000;
        let static_ptr_rva: u32 = 0x900;
        let mono_bytes = build_mono_dll(static_ptr_rva);
        // Lay the DLL out as one big region in maps:
        let maps: Vec<MapEntry> = vec![(
            mono_base,
            mono_base + mono_bytes.len() as u64,
            "r-xp".to_string(),
            Some("/abs/mono-2.0-bdwgc.dll".to_string()),
        )];
        // FakeMem reads against the live process need to mirror the DLL
        // bytes at mono_base.
        mem.add(mono_base, mono_bytes.clone());

        let domain_addr: u64 = 0x10_0000;
        // Intercept the static-pointer read with the domain address.
        // (FakeMem chooses the first matching block, so this entry
        // takes precedence over any trailing zeroes from the DLL
        // block as long as we add it before checking the read.)
        // Actually FakeMem matches by `addr >= base && off < data.len()`
        // — the DLL block at mono_base has length 0x2000, so an
        // address inside that range will resolve from the DLL block.
        // We need the DLL block's bytes at offset static_ptr_rva to
        // contain the domain_addr u64 directly.
        {
            let off = static_ptr_rva as usize;
            // Mutate the DLL bytes already in mem — easier to rebuild
            // the block:
            let mut new_dll = mono_bytes.clone();
            new_dll[off..off + 8].copy_from_slice(&domain_addr.to_le_bytes());
            // Replace the previous block:
            let mut new_blocks: Vec<(u64, Vec<u8>)> = mem
                .blocks
                .into_iter()
                .filter(|(a, _)| *a != mono_base)
                .collect();
            new_blocks.push((mono_base, new_dll));
            mem.blocks = new_blocks;
        }

        // ---- 2. MonoDomain with domain_assemblies pointing at GSList head
        let gslist_head: u64 = 0x11_0000;
        let mut domain_block = vec![0u8; 0x110];
        domain_block[offsets.domain_assemblies..offsets.domain_assemblies + 8]
            .copy_from_slice(&gslist_head.to_le_bytes());
        // domain_id = 0 (default zero from vec!)
        mem.add(domain_addr, domain_block);

        // ---- 3. Three GSList nodes, three assemblies, three images
        let core_image: u64 = 0x20_0000;
        let csharp_image: u64 = 0x20_1000;
        let mscorlib_image: u64 = 0x20_2000;

        let core_asm: u64 = 0x21_0000;
        let csharp_asm: u64 = 0x21_1000;
        let mscorlib_asm: u64 = 0x21_2000;

        let core_name_ptr: u64 = 0x22_0000;
        let csharp_name_ptr: u64 = 0x22_1000;
        let mscorlib_name_ptr: u64 = 0x22_2000;
        write_cstring(&mut mem, core_name_ptr, "Core");
        write_cstring(&mut mem, csharp_name_ptr, "Assembly-CSharp");
        write_cstring(&mut mem, mscorlib_name_ptr, "mscorlib");

        for (i, (asm_addr, name_ptr, image_addr)) in [
            (core_asm, core_name_ptr, core_image),
            (csharp_asm, csharp_name_ptr, csharp_image),
            (mscorlib_asm, mscorlib_name_ptr, mscorlib_image),
        ]
        .iter()
        .enumerate()
        {
            let mut asm = vec![0u8; offsets.assembly_image + 8];
            asm[offsets.assembly_aname_name..offsets.assembly_aname_name + 8]
                .copy_from_slice(&name_ptr.to_le_bytes());
            asm[offsets.assembly_image..offsets.assembly_image + 8]
                .copy_from_slice(&image_addr.to_le_bytes());
            mem.add(*asm_addr, asm);

            // GSList node i at gslist_head + i*16
            let node_addr = gslist_head + (i as u64) * 16;
            let next = if i < 2 {
                gslist_head + ((i + 1) as u64) * 16
            } else {
                0
            };
            let mut node = vec![0u8; 16];
            node[0..8].copy_from_slice(&asm_addr.to_le_bytes());
            node[8..16].copy_from_slice(&next.to_le_bytes());
            mem.add(node_addr, node);
        }

        // ---- 4. PAPA class in Core's class_cache
        let papa_addr: u64 = 0x30_0000;
        let papa_name_addr: u64 = 0x31_0000;
        write_cstring(&mut mem, papa_name_addr, "PAPA");

        // PAPA fields: _instance (static, offset 0x10) +
        // <InventoryManager>k__BackingField (instance, offset 0x40)
        let papa_fields_addr: u64 = 0x32_0000;
        let papa_field_names: u64 = 0x33_0000;
        let papa_field_types: u64 = 0x34_0000;
        write_cstring(&mut mem, papa_field_names, "_instance");
        write_cstring(
            &mut mem,
            papa_field_names + 0x100,
            "<InventoryManager>k__BackingField",
        );
        write_field(
            &mut mem,
            papa_fields_addr,
            0,
            papa_field_names,
            papa_field_types,
            0x10,
            true,
        );
        write_field(
            &mut mem,
            papa_fields_addr,
            1,
            papa_field_names + 0x100,
            papa_field_types + 0x100,
            0x40,
            false,
        );

        let papa_rti: u64 = 0x35_0000;
        let papa_vtable: u64 = 0x36_0000;
        let papa_storage: u64 = 0x37_0000;
        let papa_vtable_size: i32 = 3;

        write_class_def(
            &mut mem,
            papa_addr,
            papa_fields_addr,
            2,
            papa_rti,
            papa_vtable_size,
            papa_name_addr,
        );

        // RTI: max_domain=0, domain_vtables[0] = papa_vtable
        let mut rti = vec![0u8; offsets.runtime_info_domain_vtables + 8];
        rti[offsets.runtime_info_max_domain..offsets.runtime_info_max_domain + 2]
            .copy_from_slice(&0u16.to_le_bytes());
        rti[offsets.runtime_info_domain_vtables..offsets.runtime_info_domain_vtables + 8]
            .copy_from_slice(&papa_vtable.to_le_bytes());
        mem.add(papa_rti, rti);

        // VTable: static-storage slot at 0x48 + 3*8 = 0x60 → papa_storage
        let mut vt = vec![0u8; 0x70];
        vt[0x60..0x68].copy_from_slice(&papa_storage.to_le_bytes());
        mem.add(papa_vtable, vt);

        // Static storage: at offset 0x10 holds the PAPA singleton ptr
        let papa_singleton_addr: u64 = 0x40_0000;
        let mut storage = vec![0u8; 0x40];
        storage[0x10..0x18].copy_from_slice(&papa_singleton_addr.to_le_bytes());
        mem.add(papa_storage, storage);

        install_image_with_one_class(&mut mem, core_image, 0x50_0000, papa_addr);

        // ---- 5. PAPA singleton object: <InventoryManager>kBF @0x40 → IM
        let im_addr: u64 = 0x60_0000;
        let mut papa_obj = vec![0u8; 0x80];
        papa_obj[0x40..0x48].copy_from_slice(&im_addr.to_le_bytes());
        mem.add(papa_singleton_addr, papa_obj);

        // ---- 6. InventoryManager class in Assembly-CSharp + object
        let im_class_addr: u64 = 0x70_0000;
        let im_class_name_addr: u64 = 0x71_0000;
        write_cstring(&mut mem, im_class_name_addr, "InventoryManager");
        let im_fields_addr: u64 = 0x72_0000;
        let im_field_names: u64 = 0x73_0000;
        let im_field_types: u64 = 0x74_0000;
        write_cstring(&mut mem, im_field_names, "_inventoryServiceWrapper");
        write_field(
            &mut mem,
            im_fields_addr,
            0,
            im_field_names,
            im_field_types,
            0x30,
            false,
        );
        write_class_def(
            &mut mem,
            im_class_addr,
            im_fields_addr,
            1,
            0,
            0,
            im_class_name_addr,
        );

        // IM object: _inventoryServiceWrapper @0x30 → SW
        let sw_addr: u64 = 0x80_0000;
        let mut im_obj = vec![0u8; 0x80];
        im_obj[0x30..0x38].copy_from_slice(&sw_addr.to_le_bytes());
        mem.add(im_addr, im_obj);

        install_image_with_one_class(&mut mem, csharp_image, 0x50_1000, im_class_addr);

        // ---- 7. ServiceWrapper class + object: Cards @0x10, m_inventory @0x20
        // The class_lookup test fixture for Assembly-CSharp can only
        // hold one class per bucket array; we'd need a chain to host
        // multiple. To keep the test tractable we instead let the
        // walker fall back to Core for the wrapper / inventory /
        // dictionary classes — store them in additional buckets of
        // the Core image's class_cache by reusing the bucket array
        // structure with chained next_class_cache pointers.
        //
        // Easier: install separate single-bucket images for each
        // remaining class by reusing the csharp_image and stashing
        // the wrapper+inv+dict classes in a chained list via
        // next_class_cache.
        //
        // Build a chain in Assembly-CSharp's bucket array: IM → SW
        // → ClientPlayerInventory.
        let sw_class_addr: u64 = 0x90_0000;
        let sw_class_name_addr: u64 = 0x91_0000;
        write_cstring(&mut mem, sw_class_name_addr, "InventoryServiceWrapper");
        let sw_fields_addr: u64 = 0x92_0000;
        let sw_field_names: u64 = 0x93_0000;
        let sw_field_types: u64 = 0x94_0000;
        write_cstring(&mut mem, sw_field_names, "Cards");
        write_cstring(&mut mem, sw_field_names + 0x100, "m_inventory");
        write_field(
            &mut mem,
            sw_fields_addr,
            0,
            sw_field_names,
            sw_field_types,
            0x10,
            false,
        );
        write_field(
            &mut mem,
            sw_fields_addr,
            1,
            sw_field_names + 0x100,
            sw_field_types + 0x100,
            0x20,
            false,
        );
        write_class_def(
            &mut mem,
            sw_class_addr,
            sw_fields_addr,
            2,
            0,
            0,
            sw_class_name_addr,
        );

        // Dictionary obj at SW.Cards (offset 0x10)
        let dict_obj_addr: u64 = 0xA0_0000;
        let entries_array_addr: u64 = 0xA1_0000;
        let mut sw_obj = vec![0u8; 0x40];
        sw_obj[0x10..0x18].copy_from_slice(&dict_obj_addr.to_le_bytes());
        // Inventory obj at SW.m_inventory (offset 0x20)
        let inv_obj_addr: u64 = 0xB0_0000;
        sw_obj[0x20..0x28].copy_from_slice(&inv_obj_addr.to_le_bytes());
        mem.add(sw_addr, sw_obj);

        // ---- 8. Chain SW into Assembly-CSharp's class_cache.
        // The IM class is already at csharp_image. Patch IM's
        // next_class_cache (offset 0x108) to point at SW, then SW's
        // next_class_cache to point at ClientPlayerInventory.
        // Patch by re-adding the IM class blob with next_class_cache
        // populated:
        let inv_class_addr: u64 = 0xC0_0000;
        let inv_name_addr: u64 = 0xC1_0000;
        write_cstring(&mut mem, inv_name_addr, "ClientPlayerInventory");
        let inv_fields_addr: u64 = 0xC2_0000;
        let inv_field_names_base: u64 = 0xC3_0000;
        let inv_field_types_base: u64 = 0xC4_0000;
        let inv_field_names = [
            "wcCommon",
            "wcUncommon",
            "wcRare",
            "wcMythic",
            "gold",
            "gems",
            "vaultProgress",
        ];
        for (i, n) in inv_field_names.iter().enumerate() {
            write_cstring(&mut mem, inv_field_names_base + (i as u64) * 0x100, n);
            write_field(
                &mut mem,
                inv_fields_addr,
                i as u64,
                inv_field_names_base + (i as u64) * 0x100,
                inv_field_types_base + (i as u64) * 0x100,
                0x10 + (i as i32) * 4,
                false,
            );
        }
        write_class_def(
            &mut mem,
            inv_class_addr,
            inv_fields_addr,
            7,
            0,
            0,
            inv_name_addr,
        );

        // Inventory object: 7 i32 fields at 0x10, 0x14, ...
        let inv_values = [42i32, 17, 5, 2, 12_345, 3_000, 250];
        let mut inv_obj = vec![0u8; 0x40];
        for (i, v) in inv_values.iter().enumerate() {
            inv_obj[0x10 + i * 4..0x10 + i * 4 + 4].copy_from_slice(&v.to_le_bytes());
        }
        mem.add(inv_obj_addr, inv_obj);

        // Now write the IM/SW/InventoryClass with chained
        // next_class_cache pointers. Re-write the IM blob to chain
        // → SW; write SW blob with chain → InventoryClass; write
        // InventoryClass blob with chain → 0.
        let mut new_blocks: Vec<(u64, Vec<u8>)> = mem
            .blocks
            .iter()
            .filter(|(a, _)| *a != im_class_addr)
            .cloned()
            .collect();
        let im_blob_idx = mem.blocks.iter().position(|(a, _)| *a == im_class_addr);
        let mut im_blob = match im_blob_idx {
            Some(i) => mem.blocks[i].1.clone(),
            None => return Err("IM blob missing".to_string()),
        };
        im_blob[offsets.class_def_next_class_cache..offsets.class_def_next_class_cache + 8]
            .copy_from_slice(&sw_class_addr.to_le_bytes());
        new_blocks.push((im_class_addr, im_blob));

        // Add SW blob with chain → inv_class
        let mut sw_blob = vec![0u8; CLASS_DEF_BLOB_LEN];
        // Re-fill the same way write_class_def does. Easier: pull
        // the existing sw_class_addr blob from new_blocks, mutate
        // its next_class_cache field, push back.
        let (idx, _) = new_blocks
            .iter()
            .enumerate()
            .find(|(_, (a, _))| *a == sw_class_addr)
            .ok_or("SW blob must exist")?;
        sw_blob = new_blocks[idx].1.clone();
        sw_blob[offsets.class_def_next_class_cache..offsets.class_def_next_class_cache + 8]
            .copy_from_slice(&inv_class_addr.to_le_bytes());
        new_blocks[idx].1 = sw_blob;
        mem.blocks = new_blocks;

        // ---- 9. mscorlib class_cache: Dictionary`2 with _entries
        let dict_class_addr: u64 = 0xD0_0000;
        let dict_name_addr: u64 = 0xD1_0000;
        write_cstring(&mut mem, dict_name_addr, "Dictionary`2");
        let dict_fields_addr: u64 = 0xD2_0000;
        let dict_field_names: u64 = 0xD3_0000;
        let dict_field_types: u64 = 0xD4_0000;
        write_cstring(&mut mem, dict_field_names, "_entries");
        write_field(
            &mut mem,
            dict_fields_addr,
            0,
            dict_field_names,
            dict_field_types,
            0x18,
            false,
        );
        write_class_def(
            &mut mem,
            dict_class_addr,
            dict_fields_addr,
            1,
            0,
            0,
            dict_name_addr,
        );

        install_image_with_one_class(&mut mem, mscorlib_image, 0x50_2000, dict_class_addr);

        // Dictionary object: _entries @0x18 → entries_array
        let mut dict_obj = vec![0u8; 0x40];
        dict_obj[0x18..0x20].copy_from_slice(&entries_array_addr.to_le_bytes());
        mem.add(dict_obj_addr, dict_obj);

        // Entries array: capacity 2, two used entries (key=74116, value=1) and (key=32388, value=4)
        let mut header = vec![0u8; offsets.array_vector];
        header[offsets.array_max_length..offsets.array_max_length + 8]
            .copy_from_slice(&2u64.to_le_bytes());
        mem.add(entries_array_addr, header);

        let vector_addr = entries_array_addr + offsets.array_vector as u64;
        let mut blob: Vec<u8> = Vec::new();
        for (k, v) in [(74116i32, 1i32), (32388i32, 4i32)] {
            blob.extend_from_slice(&(k & 0x7FFF_FFFF).to_le_bytes());
            blob.extend_from_slice(&(-1i32).to_le_bytes());
            blob.extend_from_slice(&k.to_le_bytes());
            blob.extend_from_slice(&v.to_le_bytes());
        }
        mem.add(vector_addr, blob);

        // ---- 10. Run the orchestrator!
        let result = walk_collection(
            &maps,
            |a, l| mem.read(a, l),
            || Some("end-to-end-test-guid".to_string()),
        )
        .map_err(|e| format!("walk should succeed, got {:?}", e))?;

        assert_eq!(result.entries.len(), 2);
        assert!(result.entries.contains(&DictEntry {
            key: 74116,
            value: 1
        }));
        assert_eq!(result.inventory.wc_common, 42);
        assert_eq!(result.inventory.gold, 12_345);
        assert_eq!(result.inventory.vault_progress, 250);
        assert_eq!(
            result.mtga_build_hint.as_deref(),
            Some("end-to-end-test-guid")
        );
        Ok(())
    }
}
