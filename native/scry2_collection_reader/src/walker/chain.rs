//! Pointer-chain orchestrator — compose the walker primitives into
//! end-to-end reads of MTGA's inventory state.
//!
//! The chain from the `mono-memory-reader` skill:
//!
//! ```text
//! PAPA singleton
//!   <InventoryManager>k__BackingField
//!     _inventoryServiceWrapper  ← innermost composed level exposed today
//!       <Cards>k__BackingField   -> Dictionary<int,int>
//!       m_inventory              -> ClientPlayerInventory { 7 fields }
//! ```
//!
//! Two compositions live here:
//!
//! - [`from_service_wrapper`] is the **innermost** layer: caller
//!   has already resolved the `InventoryServiceWrapper` object
//!   address (e.g. via [`from_papa_class`] or a future top-level
//!   `walk_collection` orchestrator).
//! - [`from_papa_class`] is the **outer** layer: caller has resolved
//!   the live `MonoDomain *`, the `MonoClass *` of `PAPA`, and the
//!   `MonoClassDef` byte buffers for `PAPA`, `InventoryManager`,
//!   `InventoryServiceWrapper`, `Dictionary<int,int>`, and
//!   `ClientPlayerInventory`. It reads PAPA's static `_instance`
//!   field via [`super::vtable`], chases two instance fields
//!   (`<InventoryManager>k__BackingField` and
//!   `_inventoryServiceWrapper`), and delegates to
//!   [`from_service_wrapper`].

use super::boosters::{self, BoosterRow};
use super::dict::{self, DictEntry};
use super::field::{self, ResolvedField};
use super::inventory::{self, InventoryValues};
use super::mono::{self, MonoOffsets};
use super::object;
use super::vtable;

/// Combined result of a full walk.
///
/// `InventoryValues` carries an `f64` (`vault_progress`) so we can't
/// derive `Eq`; `PartialEq` is enough for tests and downstream
/// equality checks.
#[derive(Clone, Debug, PartialEq)]
pub struct WalkResult {
    /// Used entries from the `Cards` dictionary.
    pub entries: Vec<DictEntry>,
    /// Wildcards / currencies / vault progress.
    pub inventory: InventoryValues,
    /// Booster inventory — `(collation_id, count)` rows.
    pub boosters: Vec<BoosterRow>,
}

/// Walk from a resolved `InventoryServiceWrapper` object, deriving
/// the wrapper's runtime class (and the dict + inventory runtime
/// classes) from each instance's vtable.
///
/// Required inputs:
/// - `service_wrapper_addr` — object address in the target process.
/// - `read_mem(addr, len)` — remote-memory reader closure.
///
/// Returns `None` on any miss (unresolved field, null pointer,
/// truncated read, dict cap exceeded, etc.). The walk is
/// all-or-nothing — no partial snapshots.
///
/// Module-private: only `from_papa_class` and tests call this directly.
pub(super) fn from_service_wrapper<F>(
    offsets: &MonoOffsets,
    service_wrapper_addr: u64,
    dictionary_class_bytes: &[u8],
    read_mem: F,
) -> Option<WalkResult>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let wrapper_class_bytes = object::read_runtime_class_bytes(service_wrapper_addr, &read_mem)?;

    let cards_dict_addr = object::read_instance_pointer(
        offsets,
        &wrapper_class_bytes,
        service_wrapper_addr,
        "Cards",
        &read_mem,
    )?;

    // The cards dictionary's runtime class is the closed-generic
    // `Dictionary<int,int>` (a `MonoClassGenericInst` whose
    // `field_count` lives at a different offset than
    // `MonoClassDef.field_count`). Resolving `_entries` against the
    // *open-generic* `Dictionary\`2` definition gets us the correct
    // field offset — reference fields like `Entry[] _entries` are 8
    // bytes regardless of T/V.
    let entries_array_addr = object::read_instance_pointer(
        offsets,
        dictionary_class_bytes,
        cards_dict_addr,
        "_entries",
        &read_mem,
    )?;

    // Bound iteration by the dict's `_count` (high-water mark of
    // allocated slots). Without this, zero-init slots in the tail
    // (capacity - count) silently pass the validity predicate and
    // pollute the result with `(0, 0)` entries — that's what
    // produced the 4,104 spurious zeros that flipped the walker
    // self-check into permanent fallback for days. `_count` lives
    // on the dict object, so we resolve via the open-generic
    // dictionary class.
    let used_count = super::instance_field::read_instance_i32(
        offsets,
        dictionary_class_bytes,
        cards_dict_addr,
        "_count",
        &read_mem,
    )
    .map(|n| n.max(0) as usize);
    let entries =
        dict::read_int_int_entries(offsets, entries_array_addr, used_count, read_mem)?;

    let inv_addr = object::read_instance_pointer(
        offsets,
        &wrapper_class_bytes,
        service_wrapper_addr,
        "m_inventory",
        &read_mem,
    )?;
    let inventory_class_bytes = object::read_runtime_class_bytes(inv_addr, &read_mem)?;
    let inventory_values =
        inventory::read_inventory(offsets, &inventory_class_bytes, inv_addr, read_mem)?;

    // Boosters are a separate `boosters` field on the same
    // ClientPlayerInventory object — read here so the walker delivers
    // a single combined snapshot per call.
    //
    // A failure to read boosters does **not** fail the entire walk —
    // primary inventory is the harder requirement and pre-spike-18
    // builds already shipped without booster data. An empty Vec
    // signals "boosters not read" and the Elixir side stores nil.
    let boosters = boosters::read_boosters(offsets, &inventory_class_bytes, inv_addr, read_mem);

    Some(WalkResult {
        entries,
        inventory: inventory_values,
        boosters,
    })
}

/// Walk from a `PAPA` class down to the inventory, deriving each
/// downstream class from its **instance's vtable** at runtime
/// instead of demanding its `MonoClassDef` bytes up front.
///
/// MTGA's concrete inventory types vary across builds:
/// `MockInventoryServiceWrapper`, `HarnessInventoryServiceWrapper`,
/// `AwsInventoryServiceWrapper`, etc. all live in different
/// assemblies and the build-time substitution determines which one
/// MTGA actually instantiates. Looking up the wrapper class by
/// name is therefore brittle — instead we read
/// `wrapper_object.vtable.klass` and pick up whichever runtime
/// class is in play.
///
/// Required inputs:
/// - `papa_class_addr` — `MonoClass *` of `PAPA` in the target
///   process. PAPA itself has a stable name across builds.
/// - `domain_addr` — live `MonoDomain *`.
/// - `papa_class_bytes` — bytes of PAPA's `MonoClassDef` (covers
///   the static `_instance` field and the instance
///   `<InventoryManager>k__BackingField`).
/// - `read_mem(addr, len)` — remote-memory reader.
///
/// Returns `None` on any miss along the chain.
pub fn from_papa_class<F>(
    offsets: &MonoOffsets,
    papa_class_addr: u64,
    domain_addr: u64,
    papa_class_bytes: &[u8],
    dictionary_class_bytes: &[u8],
    read_mem: F,
) -> Option<WalkResult>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    let papa_singleton_addr = read_static_pointer(
        offsets,
        papa_class_bytes,
        papa_class_addr,
        domain_addr,
        "_instance",
        &read_mem,
    )?;

    let inventory_manager_addr = object::read_instance_pointer(
        offsets,
        papa_class_bytes,
        papa_singleton_addr,
        "InventoryManager",
        &read_mem,
    )?;

    let inventory_manager_class_bytes =
        object::read_runtime_class_bytes(inventory_manager_addr, &read_mem)?;
    let service_wrapper_addr = object::read_instance_pointer(
        offsets,
        &inventory_manager_class_bytes,
        inventory_manager_addr,
        "_inventoryServiceWrapper",
        &read_mem,
    )?;

    from_service_wrapper(
        offsets,
        service_wrapper_addr,
        dictionary_class_bytes,
        read_mem,
    )
}

/// Resolve `field_name` on the class at `class_base` inside
/// `class_bytes`, then read a pointer at `static_storage + field.offset`.
///
/// Rejects instance fields, negative offsets, and null pointers —
/// those would indicate the walker is on a wrong path or hit an
/// uninitialised static.
fn read_static_pointer<F>(
    offsets: &MonoOffsets,
    class_bytes: &[u8],
    class_addr: u64,
    domain_addr: u64,
    field_name: &str,
    read_mem: &F,
) -> Option<u64>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let resolved: ResolvedField =
        field::find_field_by_name(offsets, class_bytes, field_name, read_mem)?;
    if !resolved.is_static || resolved.offset < 0 {
        return None;
    }
    let storage = vtable::static_storage_base(offsets, class_addr, domain_addr, read_mem)?;
    let addr = storage.checked_add(resolved.offset as u64)?;
    let bytes = read_mem(addr, 8)?;
    let ptr = mono::read_u64(&bytes, 0, 0)?;
    if ptr == 0 {
        return None;
    }
    Some(ptr)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::walker::inventory::FIELD_NAMES;
    use crate::walker::mono::{DICT_INT_INT_ENTRY_SIZE, MONO_CLASS_FIELD_SIZE};
    use crate::walker::test_support::{make_type_block, FakeMem};

    fn make_field_entry(name_ptr: u64, type_ptr: u64, offset: i32) -> Vec<u8> {
        crate::walker::test_support::make_field_entry(name_ptr, type_ptr, 0, offset)
    }

    /// Install field+type entries for a class. Caller writes the
    /// MonoClass blob separately (since the field array address +
    /// count are class-blob fields).
    fn install_fields(
        mem: &mut FakeMem,
        fields_addr: u64,
        names_base: u64,
        types_base: u64,
        specs: &[(&str, i32, bool /* is_static */)],
    ) {
        let mut blob = Vec::with_capacity(specs.len() * MONO_CLASS_FIELD_SIZE);
        for (i, (name, offset, is_static)) in specs.iter().enumerate() {
            let name_ptr = names_base + (i as u64) * 0x80;
            let type_ptr = types_base + (i as u64) * 0x40;
            blob.extend_from_slice(&make_field_entry(name_ptr, type_ptr, *offset));
            let mut nbuf = name.as_bytes().to_vec();
            nbuf.push(0);
            mem.add(name_ptr, nbuf);
            let attrs: u16 = if *is_static { 0x10 } else { 0 };
            mem.add(type_ptr, make_type_block(attrs));
        }
        mem.add(fields_addr, blob);
    }

    /// Write a `MonoClassDef` blob covering fields ptr + field_count
    /// only. Used for instance-only classes (no static field /
    /// vtable resolution needed).
    fn write_class_def_simple(
        mem: &mut FakeMem,
        class_addr: u64,
        fields_addr: u64,
        field_count: u32,
    ) {
        let o = MonoOffsets::mtga_default();
        let mut buf = vec![0u8; mono::CLASS_DEF_BLOB_LEN];
        buf[o.class_fields..o.class_fields + 8].copy_from_slice(&fields_addr.to_le_bytes());
        buf[o.class_def_field_count..o.class_def_field_count + 4]
            .copy_from_slice(&field_count.to_le_bytes());
        mem.add(class_addr, buf);
    }

    /// Write a `MonoClassDef` blob carrying fields + runtime_info +
    /// vtable_size, used for classes that need static-field
    /// resolution.
    fn write_class_def_with_vtable(
        mem: &mut FakeMem,
        class_addr: u64,
        fields_addr: u64,
        field_count: u32,
        runtime_info: u64,
        vtable_size: i32,
    ) {
        let o = MonoOffsets::mtga_default();
        let mut buf = vec![0u8; mono::CLASS_DEF_BLOB_LEN];
        buf[o.class_fields..o.class_fields + 8].copy_from_slice(&fields_addr.to_le_bytes());
        buf[o.class_def_field_count..o.class_def_field_count + 4]
            .copy_from_slice(&field_count.to_le_bytes());
        buf[o.class_runtime_info..o.class_runtime_info + 8]
            .copy_from_slice(&runtime_info.to_le_bytes());
        buf[o.class_vtable_size..o.class_vtable_size + 4]
            .copy_from_slice(&(vtable_size as u32).to_le_bytes());
        mem.add(class_addr, buf);
    }

    /// Wire up `obj_addr` so that reading its first 8 bytes (vtable),
    /// then 8 bytes at the vtable's start (klass), yields `class_addr`.
    /// Allocates a synthetic vtable in FakeMem at `vtable_addr`.
    fn link_object_to_class(
        mem: &mut FakeMem,
        obj_addr: u64,
        obj_bytes: Vec<u8>,
        vtable_addr: u64,
        class_addr: u64,
    ) {
        // Object: vtable pointer at offset 0, plus the caller's payload.
        let mut obj = obj_bytes;
        if obj.len() < 8 {
            obj.resize(8, 0);
        }
        obj[0..8].copy_from_slice(&vtable_addr.to_le_bytes());
        mem.add(obj_addr, obj);

        // VTable: klass pointer at offset 0 (rest unused for runtime-class
        // resolution).
        mem.add(vtable_addr, class_addr.to_le_bytes().to_vec());
    }

    fn install_static_storage_chain(
        mem: &mut FakeMem,
        rti_addr: u64,
        vtable_addr: u64,
        storage_addr: u64,
        vtable_size: i32,
    ) {
        let o = MonoOffsets::mtga_default();
        let mut rti = vec![0u8; o.runtime_info_domain_vtables + 8];
        rti[o.runtime_info_max_domain..o.runtime_info_max_domain + 2]
            .copy_from_slice(&0u16.to_le_bytes());
        rti[o.runtime_info_domain_vtables..o.runtime_info_domain_vtables + 8]
            .copy_from_slice(&vtable_addr.to_le_bytes());
        mem.add(rti_addr, rti);

        let slot_off = o.vtable_method_slots + (vtable_size as usize) * 8;
        let mut vt = vec![0u8; slot_off + 8];
        vt[slot_off..slot_off + 8].copy_from_slice(&storage_addr.to_le_bytes());
        mem.add(vtable_addr, vt);
    }

    fn install_dict_array(mem: &mut FakeMem, array_addr: u64, entries: &[(i32, i32)]) {
        let o = MonoOffsets::mtga_default();
        let capacity = entries.len() as u64;
        let mut header = vec![0u8; o.array_vector];
        header[o.array_max_length..o.array_max_length + 8].copy_from_slice(&capacity.to_le_bytes());
        mem.add(array_addr, header);

        let vector_addr = array_addr + o.array_vector as u64;
        let mut blob = Vec::with_capacity(entries.len() * DICT_INT_INT_ENTRY_SIZE);
        for (key, value) in entries {
            blob.extend_from_slice(&(key & 0x7FFF_FFFF).to_le_bytes());
            blob.extend_from_slice(&(-1i32).to_le_bytes());
            blob.extend_from_slice(&key.to_le_bytes());
            blob.extend_from_slice(&value.to_le_bytes());
        }
        mem.add(vector_addr, blob);
    }

    // -----------------------------------------------------------------
    // read_static_pointer — exercised independently of from_papa_class.
    // -----------------------------------------------------------------

    fn make_class_def_for_static_test(class_addr: u64, fields_addr: u64) -> (u64, u64) {
        // Returns (rti_addr, vtable_addr) constants used by the test.
        let _ = (class_addr, fields_addr);
        (0x20_1000, 0x20_2000)
    }

    fn build_static_test_fixture(
        mem: &mut FakeMem,
        field_specs: &[(&str, i32, bool)],
    ) -> (Vec<u8>, u64, u64, u64) {
        // Returns (class_bytes, class_addr, domain_addr, storage_addr).
        let offsets = MonoOffsets::mtga_default();
        let class_addr: u64 = 0x20_0000;
        let fields_addr: u64 = 0x10_0000;
        let names_base: u64 = 0x10_1000;
        let types_base: u64 = 0x10_2000;
        let storage_addr: u64 = 0x20_3000;
        let domain_addr: u64 = 0x20_4000;
        let (rti_addr, vtable_addr) = make_class_def_for_static_test(class_addr, fields_addr);
        let vtable_size: i32 = 0;

        install_fields(mem, fields_addr, names_base, types_base, field_specs);

        let mut class_buf = vec![0u8; mono::CLASS_DEF_BLOB_LEN];
        class_buf[offsets.class_fields..offsets.class_fields + 8]
            .copy_from_slice(&fields_addr.to_le_bytes());
        class_buf[offsets.class_def_field_count..offsets.class_def_field_count + 4]
            .copy_from_slice(&(field_specs.len() as u32).to_le_bytes());
        class_buf[offsets.class_runtime_info..offsets.class_runtime_info + 8]
            .copy_from_slice(&rti_addr.to_le_bytes());
        class_buf[offsets.class_vtable_size..offsets.class_vtable_size + 4]
            .copy_from_slice(&(vtable_size as u32).to_le_bytes());
        mem.add(class_addr, class_buf.clone());

        let mut domain = vec![0u8; 0x100];
        domain[offsets.domain_id..offsets.domain_id + 4].copy_from_slice(&0u32.to_le_bytes());
        mem.add(domain_addr, domain);

        install_static_storage_chain(mem, rti_addr, vtable_addr, storage_addr, vtable_size);

        (class_buf, class_addr, domain_addr, storage_addr)
    }

    #[test]
    fn read_static_pointer_resolves_via_vtable_storage() -> Result<(), String> {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let (class_bytes, class_addr, domain_addr, storage_addr) =
            build_static_test_fixture(&mut mem, &[("_instance", 0x20, true)]);

        let singleton_addr: u64 = 0x99_0000;
        let mut storage = vec![0u8; 0x40];
        storage[0x20..0x20 + 8].copy_from_slice(&singleton_addr.to_le_bytes());
        mem.add(storage_addr, storage);

        let got = read_static_pointer(
            &offsets,
            &class_bytes,
            class_addr,
            domain_addr,
            "_instance",
            &|a, l| mem.read(a, l),
        )
        .ok_or("static pointer must resolve")?;
        assert_eq!(got, singleton_addr);
        Ok(())
    }

    #[test]
    fn read_static_pointer_rejects_instance_field() {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let (class_bytes, class_addr, domain_addr, _) =
            build_static_test_fixture(&mut mem, &[("_instance", 0x20, false /* instance */)]);

        assert_eq!(
            read_static_pointer(
                &offsets,
                &class_bytes,
                class_addr,
                domain_addr,
                "_instance",
                &|a, l| mem.read(a, l),
            ),
            None
        );
    }

    #[test]
    fn read_static_pointer_resolves_backing_field_form() -> Result<(), String> {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let (class_bytes, class_addr, domain_addr, storage_addr) =
            build_static_test_fixture(&mut mem, &[("<Instance>k__BackingField", 0x20, true)]);

        let singleton_addr: u64 = 0x99_0000;
        let mut storage = vec![0u8; 0x40];
        storage[0x20..0x20 + 8].copy_from_slice(&singleton_addr.to_le_bytes());
        mem.add(storage_addr, storage);

        let got = read_static_pointer(
            &offsets,
            &class_bytes,
            class_addr,
            domain_addr,
            "_instance",
            &|a, l| mem.read(a, l),
        )
        .ok_or("backing-field form must resolve via two-pass")?;
        assert_eq!(got, singleton_addr);
        Ok(())
    }

    // -----------------------------------------------------------------
    // from_service_wrapper — vtable-driven class derivation.
    // -----------------------------------------------------------------

    /// Build a FakeMem fixture for the inner service-wrapper walk.
    /// Each instance object has its first 8 bytes set to its synthetic
    /// vtable; each vtable holds the klass at offset 0; each klass has
    /// a `MonoClassDef` blob describing the fields the walker reads.
    fn build_service_wrapper_fixture(
        mem: &mut FakeMem,
        wrapper_field_specs: &[(&str, i32, bool)],
        cards: &[(i32, i32)],
        // First six are i32 (wcCommon..gems); seventh is f64
        // (vaultProgress).
        inventory_int_values: [i32; 6],
        inventory_vault_progress: f64,
    ) -> u64 {
        // Each entity owns its own 0x10000-byte sandbox so 0x40-byte
        // objects can't shadow nearby vtables / class blobs in
        // FakeMem's first-match-wins lookup.
        let wrapper_addr: u64 = 0x70_0000;
        let wrapper_vtable: u64 = 0x71_0000;
        let wrapper_class: u64 = 0x72_0000;
        let wrapper_fields_addr: u64 = 0x73_0000;
        install_fields(
            mem,
            wrapper_fields_addr,
            0x74_0000,
            0x75_0000,
            wrapper_field_specs,
        );
        write_class_def_simple(
            mem,
            wrapper_class,
            wrapper_fields_addr,
            wrapper_field_specs.len() as u32,
        );

        // ---- Inventory object + class
        let inv_addr: u64 = 0x40_0000;
        let inv_vtable: u64 = 0x41_0000;
        let inv_class: u64 = 0x42_0000;
        let inv_fields_addr: u64 = 0x43_0000;
        // Six i32 fields at 0x10..0x28 (4-byte stride), then a
        // double-aligned f64 vaultProgress at 0x28.
        let inv_specs: Vec<(&str, i32, bool)> = FIELD_NAMES
            .iter()
            .enumerate()
            .map(|(i, n)| (*n, 0x10 + i as i32 * 4, false))
            .collect();
        install_fields(mem, inv_fields_addr, 0x44_0000, 0x45_0000, &inv_specs);
        write_class_def_simple(mem, inv_class, inv_fields_addr, inv_specs.len() as u32);
        let mut inv_obj = vec![0u8; 0x40];
        for (i, v) in inventory_int_values.iter().enumerate() {
            let off = 0x10 + i * 4;
            inv_obj[off..off + 4].copy_from_slice(&v.to_le_bytes());
        }
        // vaultProgress at offset 0x28 (4-byte stride after gems @0x24).
        inv_obj[0x28..0x30].copy_from_slice(&inventory_vault_progress.to_bits().to_le_bytes());
        link_object_to_class(mem, inv_addr, inv_obj, inv_vtable, inv_class);

        // ---- Dictionary object + class + entries array
        let dict_addr: u64 = 0x30_0000;
        let dict_vtable: u64 = 0x31_0000;
        let dict_class: u64 = 0x32_0000;
        let dict_fields_addr: u64 = 0x33_0000;
        install_fields(
            mem,
            dict_fields_addr,
            0x34_0000,
            0x35_0000,
            &[("_entries", 0x18, false)],
        );
        write_class_def_simple(mem, dict_class, dict_fields_addr, 1);
        let entries_array_addr: u64 = 0x36_0000;
        let mut dict_obj = vec![0u8; 0x40];
        dict_obj[0x18..0x18 + 8].copy_from_slice(&entries_array_addr.to_le_bytes());
        link_object_to_class(mem, dict_addr, dict_obj, dict_vtable, dict_class);
        install_dict_array(mem, entries_array_addr, cards);

        // ---- Wrapper object payload
        let mut wrapper_obj = vec![0u8; 0x40];
        wrapper_obj[0x10..0x10 + 8].copy_from_slice(&dict_addr.to_le_bytes());
        wrapper_obj[0x20..0x20 + 8].copy_from_slice(&inv_addr.to_le_bytes());
        link_object_to_class(
            mem,
            wrapper_addr,
            wrapper_obj,
            wrapper_vtable,
            wrapper_class,
        );

        wrapper_addr
    }

    #[test]
    fn from_service_wrapper_returns_both_halves() -> Result<(), String> {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let wrapper_addr = build_service_wrapper_fixture(
            &mut mem,
            &[("Cards", 0x10, false), ("m_inventory", 0x20, false)],
            &[(74116, 1), (32388, 4), (106_219, 3)],
            [42, 17, 5, 2, 12_345, 3_000],
            30.1,
        );

        let dict_bytes = mem
            .read(0x32_0000, mono::CLASS_DEF_BLOB_LEN)
            .ok_or("dict class read")?;
        let result =
            from_service_wrapper(&offsets, wrapper_addr, &dict_bytes, |a, l| mem.read(a, l))
                .ok_or("walk should succeed")?;

        assert_eq!(result.entries.len(), 3);
        assert!(result.entries.contains(&dict::DictEntry {
            key: 74116,
            value: 1
        }));
        assert_eq!(result.inventory.wc_common, 42);
        assert_eq!(result.inventory.gold, 12_345);
        assert_eq!(result.inventory.vault_progress, 30.1);
        Ok(())
    }

    #[test]
    fn from_service_wrapper_resolves_cards_via_backing_field_form() -> Result<(), String> {
        // Wrapper exposes <Cards>k__BackingField rather than literal "Cards".
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let wrapper_addr = build_service_wrapper_fixture(
            &mut mem,
            &[
                ("<Cards>k__BackingField", 0x10, false),
                ("m_inventory", 0x20, false),
            ],
            &[(7, 1)],
            [1, 1, 1, 1, 1, 1],
            0.0,
        );

        let dict_bytes = mem
            .read(0x32_0000, mono::CLASS_DEF_BLOB_LEN)
            .ok_or("dict class read")?;
        let result =
            from_service_wrapper(&offsets, wrapper_addr, &dict_bytes, |a, l| mem.read(a, l))
                .ok_or("walk should succeed via backing-field form")?;
        assert_eq!(result.entries, vec![dict::DictEntry { key: 7, value: 1 }]);
        Ok(())
    }

    #[test]
    fn from_service_wrapper_returns_none_when_cards_pointer_is_null() -> Result<(), String> {
        // Re-use the fixture but zero out the wrapper's Cards field.
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let wrapper_addr = build_service_wrapper_fixture(
            &mut mem,
            &[("Cards", 0x10, false), ("m_inventory", 0x20, false)],
            &[(7, 1)],
            [1, 1, 1, 1, 1, 1],
            0.0,
        );

        // Replace the wrapper object's Cards slot with NULL.
        let mut zeroed_obj = vec![0u8; 0x40];
        let wrapper_vtable: u64 = 0x71_0000;
        zeroed_obj[0..8].copy_from_slice(&wrapper_vtable.to_le_bytes());
        mem.replace(wrapper_addr, zeroed_obj);

        let dict_bytes = mem
            .read(0x32_0000, mono::CLASS_DEF_BLOB_LEN)
            .ok_or("dict class read")?;
        assert_eq!(
            from_service_wrapper(&offsets, wrapper_addr, &dict_bytes, |a, l| mem.read(a, l)),
            None
        );
        Ok(())
    }

    // -----------------------------------------------------------------
    // from_papa_class — outer composition test.
    // -----------------------------------------------------------------

    #[test]
    fn from_papa_class_walks_static_then_runtime_classes() -> Result<(), String> {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();

        // Reuse the service_wrapper fixture; it provides everything from
        // the wrapper down. We then build PAPA on top.
        let wrapper_addr = build_service_wrapper_fixture(
            &mut mem,
            &[("Cards", 0x10, false), ("m_inventory", 0x20, false)],
            &[(74116, 1), (32388, 4)],
            [42, 17, 5, 2, 12_345, 3_000],
            30.1,
        );

        // ---- IM object + class
        let im_addr: u64 = 0x90_0000;
        let im_vtable: u64 = 0x91_0000;
        let im_class: u64 = 0x92_0000;
        let im_fields_addr: u64 = 0x93_0000;
        install_fields(
            &mut mem,
            im_fields_addr,
            0x94_0000,
            0x95_0000,
            &[("_inventoryServiceWrapper", 0x30, false)],
        );
        write_class_def_simple(&mut mem, im_class, im_fields_addr, 1);
        let mut im_obj = vec![0u8; 0x80];
        im_obj[0x30..0x38].copy_from_slice(&wrapper_addr.to_le_bytes());
        link_object_to_class(&mut mem, im_addr, im_obj, im_vtable, im_class);

        // ---- PAPA class with static `_instance` + instance
        // `<InventoryManager>k__BackingField`
        let papa_class_addr: u64 = 0xB0_0000;
        let papa_fields_addr: u64 = 0xA0_0000;
        let papa_rti: u64 = 0xB1_0000;
        let papa_vtable: u64 = 0xB2_0000;
        let papa_storage: u64 = 0xB3_0000;
        let domain_addr: u64 = 0xB4_0000;
        let papa_vtable_size: i32 = 3;

        install_fields(
            &mut mem,
            papa_fields_addr,
            0xA1_0000,
            0xA2_0000,
            &[
                ("_instance", 0x10, true),
                ("<InventoryManager>k__BackingField", 0x40, false),
            ],
        );
        write_class_def_with_vtable(
            &mut mem,
            papa_class_addr,
            papa_fields_addr,
            2,
            papa_rti,
            papa_vtable_size,
        );

        let mut domain = vec![0u8; 0x100];
        domain[offsets.domain_id..offsets.domain_id + 4].copy_from_slice(&0u32.to_le_bytes());
        mem.add(domain_addr, domain);
        install_static_storage_chain(
            &mut mem,
            papa_rti,
            papa_vtable,
            papa_storage,
            papa_vtable_size,
        );

        // PAPA's static storage at offset 0x10 holds the singleton ptr.
        let papa_singleton: u64 = 0xC0_0000;
        let mut storage = vec![0u8; 0x40];
        storage[0x10..0x18].copy_from_slice(&papa_singleton.to_le_bytes());
        mem.add(papa_storage, storage);

        // PAPA singleton: instance field at 0x40 → IM.
        let mut papa_obj = vec![0u8; 0x80];
        papa_obj[0x40..0x48].copy_from_slice(&im_addr.to_le_bytes());
        mem.add(papa_singleton, papa_obj);

        // Re-fetch the papa_class_bytes + dict_class_bytes the
        // walker will pass back in.
        let papa_class_bytes = mem
            .read(papa_class_addr, mono::CLASS_DEF_BLOB_LEN)
            .ok_or("papa class read")?;
        let dict_class_bytes = mem
            .read(0x32_0000, mono::CLASS_DEF_BLOB_LEN)
            .ok_or("dict class read")?;

        let result = from_papa_class(
            &offsets,
            papa_class_addr,
            domain_addr,
            &papa_class_bytes,
            &dict_class_bytes,
            |a, l| mem.read(a, l),
        )
        .ok_or("walk should succeed")?;

        assert_eq!(result.entries.len(), 2);
        assert!(result.entries.contains(&dict::DictEntry {
            key: 74116,
            value: 1
        }));
        assert_eq!(result.inventory.gold, 12_345);
        Ok(())
    }
}
