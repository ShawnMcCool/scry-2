//! Resolve a named field on a `MonoClassDef`.
//!
//! Implements the two-pass field-resolution rule from spike 5:
//!
//! 1. Exact name match against `MonoClassField.name`.
//! 2. If (1) misses, try `<UpperCamel>k__BackingField` form —
//!    a leading single underscore is stripped, then the first
//!    character is uppercased. C# auto-property backing fields
//!    use this naming convention.
//!
//! The `find_field_by_name` function works against bytes already read from
//! the target process. The per-entry name and per-field `MonoType`
//! reads (both require chasing pointers into arbitrary remote
//! memory) are delegated to a caller-supplied reader closure — in
//! production that calls into the NIF's platform `read_bytes`; in
//! unit tests it's a `HashMap`-backed stub.

use super::limits::MAX_NAME_LEN;
use super::mono::{self, MonoOffsets, CLASS_DEF_BLOB_LEN, MONO_CLASS_FIELD_SIZE};

/// Cap on parent-chain traversal in [`find_field_by_name_in_chain`].
/// Real Mono inheritance trees are shallow (typically 2-4 levels);
/// a hard ceiling guards against pathological / corrupted parent
/// pointers walking forever.
pub const MAX_PARENT_DEPTH: usize = 6;

/// A matched field's decoded information.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ResolvedField {
    /// Pointer to the field's `MonoType` in the target process.
    pub type_ptr: u64,
    /// Pointer to the declaring `MonoClass` in the target process.
    pub parent_ptr: u64,
    /// `MonoClassField.offset`. For instance fields, the byte offset
    /// from the start of an object of the declaring class. For static
    /// fields, the byte offset into the class's vtable static
    /// storage. `-1` means "special static, not yet assigned".
    pub offset: i32,
    /// Whether the field carries `MONO_FIELD_ATTR_STATIC`. Determines
    /// whether the walker should read from `vtable->data[offset]` or
    /// from `obj_ptr + offset`.
    pub is_static: bool,
    /// The name as actually found in memory. Equal to the requested
    /// name on exact match; equal to `<UpperCamel>k__BackingField` on
    /// backing-field match.
    pub name_found: String,
}

/// Compute the backing-field name for `name` per the spike 5 rule:
/// strip one leading underscore (if present), uppercase the first
/// character, wrap in `<...>k__BackingField`.
///
/// Returns `None` if the result would be empty (input is empty or
/// a bare `"_"`).
pub fn backing_field_name(name: &str) -> Option<String> {
    let trimmed = name.strip_prefix('_').unwrap_or(name);
    if trimmed.is_empty() {
        return None;
    }
    let mut chars = trimmed.chars();
    let first = chars.next()?;
    let mut result = String::with_capacity(trimmed.len() + "<>k__BackingField".len());
    result.push('<');
    for c in first.to_uppercase() {
        result.push(c);
    }
    result.push_str(chars.as_str());
    result.push_str(">k__BackingField");
    Some(result)
}

/// Find a field named `target_name` on the `MonoClassDef` whose bytes
/// begin at offset 0 inside `class_bytes`.
///
/// `read_mem(addr, len)` fetches `len` bytes from the target process
/// at remote address `addr`. It returns `None` on any read failure —
/// `find_field_by_name` propagates `None` only when iteration cannot
/// continue (bad buffer sizes, arithmetic overflow); otherwise a
/// read miss for a specific entry just makes that entry a non-match
/// and iteration continues.
///
/// When both an exact match and a backing-field match exist on the
/// same class, the exact match wins (spike 5's explicit ordering).
pub fn find_field_by_name<F>(
    offsets: &MonoOffsets,
    class_bytes: &[u8],
    target_name: &str,
    read_mem: F,
) -> Option<ResolvedField>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let fields_ptr = mono::class_fields_ptr(offsets, class_bytes, 0)?;
    if fields_ptr == 0 {
        return None;
    }
    let count = mono::class_def_field_count(offsets, class_bytes, 0)? as usize;

    let target_bytes = target_name.as_bytes();
    let backing = backing_field_name(target_name);

    let mut backing_match: Option<ResolvedField> = None;

    for i in 0..count {
        let step = (i as u64).checked_mul(MONO_CLASS_FIELD_SIZE as u64)?;
        let entry_addr = fields_ptr.checked_add(step)?;
        let Some(entry_buf) = read_mem(entry_addr, MONO_CLASS_FIELD_SIZE) else {
            continue;
        };
        if entry_buf.len() < MONO_CLASS_FIELD_SIZE {
            continue;
        }

        let Some(name_ptr) = mono::field_name_ptr(offsets, &entry_buf, 0) else {
            continue;
        };
        if name_ptr == 0 {
            continue;
        }
        let Some(name_buf) = read_mem(name_ptr, MAX_NAME_LEN) else {
            continue;
        };
        let end = name_buf
            .iter()
            .position(|&b| b == 0)
            .unwrap_or(name_buf.len());
        let name_bytes = &name_buf[..end];

        let is_exact = name_bytes == target_bytes;
        let is_backing = backing
            .as_ref()
            .map(|b| name_bytes == b.as_bytes())
            .unwrap_or(false);

        if !is_exact && !is_backing {
            continue;
        }

        let Some(resolved) = decode_entry(offsets, &entry_buf, name_bytes, &read_mem) else {
            continue;
        };

        if is_exact {
            // Exact match wins outright; no need to keep searching.
            return Some(resolved);
        }
        // Backing match: remember the first one we see, keep looking
        // for an exact match that might supersede it.
        if backing_match.is_none() {
            backing_match = Some(resolved);
        }
    }

    backing_match
}

/// Resolve a named field by walking the class's parent chain when the
/// own class doesn't declare it.
///
/// Many MTGA field-bearing classes inherit core fields from a base
/// class — `_previousLayoutData` lives on `CardHolderBase` (parent of
/// every per-zone holder), and `_model` lives on `BASE_CDC` (parent of
/// `DuelScene_CDC`). A flat [`find_field_by_name`] against the
/// runtime class would silently miss these.
///
/// Walks `MonoClass.parent` (offset [`MonoOffsets::class_parent`]) up
/// to [`MAX_PARENT_DEPTH`] levels, calling [`find_field_by_name`] at
/// each. Stops at a null parent (`System.Object`) or when the parent
/// class def cannot be read.
///
/// `read_mem` here must be `Copy` — unlike [`find_field_by_name`],
/// the closure is invoked per parent-chain level.
pub fn find_field_by_name_in_chain<F>(
    offsets: &MonoOffsets,
    class_bytes: &[u8],
    target_name: &str,
    read_mem: F,
) -> Option<ResolvedField>
where
    F: Fn(u64, usize) -> Option<Vec<u8>> + Copy,
{
    if let Some(f) = find_field_by_name(offsets, class_bytes, target_name, read_mem) {
        return Some(f);
    }

    let mut current = class_bytes.to_vec();
    for _ in 0..MAX_PARENT_DEPTH {
        let parent_addr = mono::class_parent_ptr(offsets, &current, 0)?;
        if parent_addr == 0 {
            return None;
        }
        let parent_bytes = read_mem(parent_addr, CLASS_DEF_BLOB_LEN)?;
        if parent_bytes.len() < CLASS_DEF_BLOB_LEN {
            return None;
        }
        if let Some(f) = find_field_by_name(offsets, &parent_bytes, target_name, read_mem) {
            return Some(f);
        }
        current = parent_bytes;
    }
    None
}

fn decode_entry<F>(
    offsets: &MonoOffsets,
    entry_buf: &[u8],
    name_bytes: &[u8],
    read_mem: &F,
) -> Option<ResolvedField>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    let type_ptr = mono::field_type_ptr(offsets, entry_buf, 0)?;
    let parent_ptr = mono::field_parent_ptr(offsets, entry_buf, 0)?;
    let offset = mono::field_offset_value(offsets, entry_buf, 0)?;

    // 12 bytes covers the 8-byte `data` union and the 4-byte bitfield
    // word where `attrs` lives.
    let type_buf = read_mem(type_ptr, 12)?;
    let attrs = mono::type_attrs(offsets, &type_buf, 0)?;
    let is_static = mono::attrs_is_static(attrs);

    let name_found = String::from_utf8_lossy(name_bytes).into_owned();

    Some(ResolvedField {
        type_ptr,
        parent_ptr,
        offset,
        is_static,
        name_found,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::walker::test_support::{
        make_class_def, make_class_def_with_parent, make_field_entry, make_type_block, FakeMem,
    };
    use std::collections::HashMap;

    // --- backing_field_name ---

    #[test]
    fn backing_field_name_upper_first_letter() {
        assert_eq!(
            backing_field_name("Cards").as_deref(),
            Some("<Cards>k__BackingField")
        );
    }

    #[test]
    fn backing_field_name_lowercases_first_letter() {
        assert_eq!(
            backing_field_name("cards").as_deref(),
            Some("<Cards>k__BackingField")
        );
    }

    #[test]
    fn backing_field_name_strips_leading_underscore() {
        assert_eq!(
            backing_field_name("_instance").as_deref(),
            Some("<Instance>k__BackingField")
        );
    }

    #[test]
    fn backing_field_name_camel_case_preserves_rest() {
        assert_eq!(
            backing_field_name("inventoryManager").as_deref(),
            Some("<InventoryManager>k__BackingField")
        );
    }

    #[test]
    fn backing_field_name_underscore_before_upper_still_strips() {
        assert_eq!(
            backing_field_name("_AlreadyUpper").as_deref(),
            Some("<AlreadyUpper>k__BackingField")
        );
    }

    #[test]
    fn backing_field_name_empty_input_is_none() {
        assert_eq!(backing_field_name(""), None);
    }

    #[test]
    fn backing_field_name_bare_underscore_is_none() {
        assert_eq!(backing_field_name("_"), None);
    }

    #[test]
    fn backing_field_name_leaves_inner_underscores_alone() {
        // spike 5 only strips a single *leading* underscore
        assert_eq!(
            backing_field_name("m_inventory").as_deref(),
            Some("<M_inventory>k__BackingField")
        );
    }

    // --- find_field_by_name ---

    /// Populate a FakeMem with `n` MonoClassField entries, each
    /// pointing at a named string and a non-static MonoType. Returns
    /// (fields_array_base, parent_ptr).
    fn populate_class(mem: &mut FakeMem, names: &[&str]) -> (u64, u64) {
        let fields_base: u64 = 0x1_0000_0000;
        let names_base: u64 = 0x2_0000_0000;
        let types_base: u64 = 0x3_0000_0000;
        let parent_ptr: u64 = 0xabcd_abcd_abcd_abcd;

        // Field entries, laid out contiguously, each pointing at an
        // individually-allocated name and type block.
        let mut entry_blob = Vec::with_capacity(names.len() * MONO_CLASS_FIELD_SIZE);
        for (i, name) in names.iter().enumerate() {
            let name_ptr = names_base + (i as u64) * 0x40;
            let type_ptr = types_base + (i as u64) * 0x20;
            let entry = make_field_entry(name_ptr, type_ptr, parent_ptr, 0x100 + (i as i32) * 8);
            entry_blob.extend_from_slice(&entry);

            let mut name_buf = name.as_bytes().to_vec();
            name_buf.push(0); // null terminator
            mem.add(name_ptr, name_buf);

            mem.add(type_ptr, make_type_block(0));
        }
        mem.add(fields_base, entry_blob);

        (fields_base, parent_ptr)
    }

    #[test]
    fn find_by_name_returns_none_when_field_missing() {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let (fields_ptr, _) = populate_class(&mut mem, &["alpha", "beta", "gamma"]);
        let class_buf = make_class_def(fields_ptr, 3);

        let hit = find_field_by_name(&offsets, &class_buf, "missing", |a, l| mem.read(a, l));
        assert_eq!(hit, None);
    }

    #[test]
    fn find_by_name_exact_match_returns_field() -> Result<(), String> {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let (fields_ptr, parent_ptr) = populate_class(
            &mut mem,
            &["_inventoryServiceWrapper", "m_inventory", "_other"],
        );
        let class_buf = make_class_def(fields_ptr, 3);

        let hit = find_field_by_name(&offsets, &class_buf, "m_inventory", |a, l| {
            mem.read(a, l)
        })
        .ok_or("m_inventory should match exactly")?;

        assert_eq!(hit.name_found, "m_inventory");
        assert_eq!(hit.parent_ptr, parent_ptr);
        assert!(!hit.is_static);
        // entries are laid out in order: m_inventory is index 1,
        // offset = 0x100 + 1*8 = 0x108.
        assert_eq!(hit.offset, 0x108);
        Ok(())
    }

    #[test]
    fn find_by_name_falls_back_to_backing_field_form() -> Result<(), String> {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let (fields_ptr, _) = populate_class(&mut mem, &["<Cards>k__BackingField", "m_inventory"]);
        let class_buf = make_class_def(fields_ptr, 2);

        let hit = find_field_by_name(&offsets, &class_buf, "Cards", |a, l| mem.read(a, l))
            .ok_or("should find via backing-field fallback")?;

        assert_eq!(hit.name_found, "<Cards>k__BackingField");
        Ok(())
    }

    #[test]
    fn find_by_name_exact_wins_over_backing_on_same_class() -> Result<(), String> {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let (fields_ptr, _) = populate_class(&mut mem, &["<Cards>k__BackingField", "cards"]);
        let class_buf = make_class_def(fields_ptr, 2);

        let hit = find_field_by_name(&offsets, &class_buf, "cards", |a, l| mem.read(a, l))
            .ok_or("should find something")?;

        assert_eq!(hit.name_found, "cards");
        Ok(())
    }

    #[test]
    fn find_by_name_reports_static_when_attr_bit_set() -> Result<(), String> {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let fields_base: u64 = 0x1000;
        let name_ptr: u64 = 0x2000;
        let type_ptr: u64 = 0x3000;
        let parent_ptr: u64 = 0x4000;

        let entry = make_field_entry(name_ptr, type_ptr, parent_ptr, 0x50);
        mem.add(fields_base, entry);
        mem.add(name_ptr, {
            let mut v = b"<Instance>k__BackingField".to_vec();
            v.push(0);
            v
        });
        mem.add(type_ptr, make_type_block(mono::MONO_FIELD_ATTR_STATIC));

        let class_buf = make_class_def(fields_base, 1);
        let hit = find_field_by_name(&offsets, &class_buf, "_instance", |a, l| mem.read(a, l))
            .ok_or("static backing field should resolve")?;

        assert!(hit.is_static);
        assert_eq!(hit.name_found, "<Instance>k__BackingField");
        Ok(())
    }

    #[test]
    fn find_by_name_returns_none_when_fields_ptr_is_null() {
        let offsets = MonoOffsets::mtga_default();
        let mem = FakeMem::default();
        let class_buf = make_class_def(0, 7);
        assert_eq!(
            find_field_by_name(&offsets, &class_buf, "anything", |a, l| mem.read(a, l)),
            None
        );
    }

    #[test]
    fn find_by_name_returns_none_when_field_count_is_zero() {
        let offsets = MonoOffsets::mtga_default();
        let mem = FakeMem::default();
        let class_buf = make_class_def(0x1000, 0);
        assert_eq!(
            find_field_by_name(&offsets, &class_buf, "anything", |a, l| mem.read(a, l)),
            None
        );
    }

    #[test]
    fn find_by_name_skips_entries_with_unreadable_name_pointers() -> Result<(), String> {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();

        // Two entries: first has unreadable name_ptr, second is valid.
        let fields_base: u64 = 0x1000;
        let bad_name: u64 = 0x9999_9999_9999_9999; // not in mem
        let good_name: u64 = 0x2000;
        let type_ptr: u64 = 0x3000;

        let mut blob = Vec::new();
        blob.extend_from_slice(&make_field_entry(bad_name, type_ptr, 0, 0x10));
        blob.extend_from_slice(&make_field_entry(good_name, type_ptr, 0, 0x20));
        mem.add(fields_base, blob);

        mem.add(good_name, {
            let mut v = b"wanted".to_vec();
            v.push(0);
            v
        });
        mem.add(type_ptr, make_type_block(0));

        let class_buf = make_class_def(fields_base, 2);
        let hit = find_field_by_name(&offsets, &class_buf, "wanted", |a, l| mem.read(a, l))
            .ok_or("second entry should match after first is skipped")?;
        assert_eq!(hit.name_found, "wanted");
        assert_eq!(hit.offset, 0x20);
        Ok(())
    }

    // --- find_field_by_name_in_chain ---

    /// Build a class with a single named field (offset 0x40, non-static)
    /// and a configurable parent pointer. Returns the class blob and
    /// installs the field-array bytes into `mem`.
    fn build_class_with_field(
        mem: &mut FakeMem,
        fields_base: u64,
        names_base: u64,
        types_base: u64,
        parent_ptr: u64,
        field_name: &str,
    ) -> Vec<u8> {
        let entry = make_field_entry(names_base, types_base, 0, 0x40);
        mem.add(fields_base, entry);
        let mut name_buf = field_name.as_bytes().to_vec();
        name_buf.push(0);
        mem.add(names_base, name_buf);
        mem.add(types_base, make_type_block(0));
        make_class_def_with_parent(fields_base, 1, parent_ptr)
    }

    #[test]
    fn find_in_chain_finds_field_on_self() -> Result<(), String> {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();
        let class_buf =
            build_class_with_field(&mut mem, 0x1000, 0x2000, 0x3000, 0, "_self_field");

        let hit = find_field_by_name_in_chain(&offsets, &class_buf, "_self_field", |a, l| {
            mem.read(a, l)
        })
        .ok_or("self field should resolve")?;
        assert_eq!(hit.name_found, "_self_field");
        Ok(())
    }

    #[test]
    fn find_in_chain_walks_to_parent_when_self_misses() -> Result<(), String> {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();

        // Parent class declares "_parent_field"; install at addr 0x10000.
        let parent_class_addr: u64 = 0x10000;
        let parent_blob =
            build_class_with_field(&mut mem, 0x11000, 0x12000, 0x13000, 0, "_parent_field");
        mem.add(parent_class_addr, parent_blob);

        // Child class declares only "_other"; parent points to parent_class_addr.
        let child_blob = build_class_with_field(
            &mut mem,
            0x21000,
            0x22000,
            0x23000,
            parent_class_addr,
            "_other",
        );

        let hit = find_field_by_name_in_chain(&offsets, &child_blob, "_parent_field", |a, l| {
            mem.read(a, l)
        })
        .ok_or("parent field should resolve via chain walk")?;
        assert_eq!(hit.name_found, "_parent_field");
        Ok(())
    }

    #[test]
    fn find_in_chain_walks_multiple_levels() -> Result<(), String> {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();

        // Grandparent declares "_target".
        let grandparent_addr: u64 = 0x10000;
        let grandparent_blob = build_class_with_field(
            &mut mem, 0x11000, 0x12000, 0x13000, 0, "_target",
        );
        mem.add(grandparent_addr, grandparent_blob);

        // Parent declares "_other_a", parent → grandparent.
        let parent_addr: u64 = 0x20000;
        let parent_blob = build_class_with_field(
            &mut mem, 0x21000, 0x22000, 0x23000, grandparent_addr, "_other_a",
        );
        mem.add(parent_addr, parent_blob);

        // Child declares "_other_b", parent → parent.
        let child_blob = build_class_with_field(
            &mut mem, 0x31000, 0x32000, 0x33000, parent_addr, "_other_b",
        );

        let hit = find_field_by_name_in_chain(&offsets, &child_blob, "_target", |a, l| {
            mem.read(a, l)
        })
        .ok_or("grandparent field should resolve")?;
        assert_eq!(hit.name_found, "_target");
        Ok(())
    }

    #[test]
    fn find_in_chain_returns_none_when_chain_exhausted() {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();

        // Parent declares only "_other"; chain ends at null parent.
        let parent_addr: u64 = 0x10000;
        let parent_blob =
            build_class_with_field(&mut mem, 0x11000, 0x12000, 0x13000, 0, "_other");
        mem.add(parent_addr, parent_blob);

        // Child declares only "_yet_other".
        let child_blob = build_class_with_field(
            &mut mem,
            0x21000,
            0x22000,
            0x23000,
            parent_addr,
            "_yet_other",
        );

        assert_eq!(
            find_field_by_name_in_chain(&offsets, &child_blob, "_missing", |a, l| mem.read(a, l)),
            None
        );
    }

    #[test]
    fn find_in_chain_self_match_short_circuits_parent_walk() -> Result<(), String> {
        let offsets = MonoOffsets::mtga_default();
        let mut mem = FakeMem::default();

        // Parent has "shared" at offset 0x40.
        let parent_addr: u64 = 0x10000;
        let parent_blob =
            build_class_with_field(&mut mem, 0x11000, 0x12000, 0x13000, 0, "shared");
        mem.add(parent_addr, parent_blob);

        // Child also has "shared" at offset 0x40 — same field name,
        // different class. Self should win.
        let child_blob = build_class_with_field(
            &mut mem,
            0x21000,
            0x22000,
            0x23000,
            parent_addr,
            "shared",
        );

        let hit = find_field_by_name_in_chain(&offsets, &child_blob, "shared", |a, l| {
            mem.read(a, l)
        })
        .ok_or("should match self")?;
        assert_eq!(hit.name_found, "shared");
        // Both are at 0x40 in this fixture, so we can't disambiguate by
        // offset; the assertion is that we got something.
        Ok(())
    }

    #[test]
    fn find_by_name_uses_supplied_hashmap_reader() -> Result<(), String> {
        // Sanity check that the closure parameter is fully generic
        // and works against a plain HashMap too.
        let offsets = MonoOffsets::mtga_default();
        let fields_base: u64 = 0x10;
        let name_ptr: u64 = 0x50;
        let type_ptr: u64 = 0xa0;

        let entry = make_field_entry(name_ptr, type_ptr, 0, 0x40);
        let mut name_bytes = b"x".to_vec();
        name_bytes.push(0);
        let type_bytes = make_type_block(0);

        let mut map: HashMap<u64, Vec<u8>> = HashMap::new();
        map.insert(fields_base, entry);
        map.insert(name_ptr, name_bytes);
        map.insert(type_ptr, type_bytes);

        let class_buf = make_class_def(fields_base, 1);
        let hit = find_field_by_name(&offsets, &class_buf, "x", |a, l| {
            map.get(&a).map(|v| v[..v.len().min(l)].to_vec())
        })
        .ok_or("single-entry HashMap should resolve")?;

        assert_eq!(hit.name_found, "x");
        Ok(())
    }
}
