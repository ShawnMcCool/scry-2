//! Mono runtime struct accessors.
//!
//! This module does not bake in struct offsets. Instead it exposes:
//!
//! 1. Little-endian, bounds-checked byte-buffer primitives (`read_u8`,
//!    `read_u16`, `read_u32`, `read_u64`, `read_ptr`).
//! 2. A per-build offset table (`MonoOffsets`) listing every field the
//!    walker consumes.
//! 3. High-level accessors (e.g. `class_fields_ptr`) that take an
//!    `&MonoOffsets`, a byte buffer, and a base offset, and apply the
//!    correct primitive to the correct field offset.
//!
//! Absolute struct offsets are known to vary across Unity/Mono build
//! flags (`DISABLE_REMOTING`, `DISABLE_COM`, bitfield packing under
//! MSVC vs Itanium ABIs). Rather than pin values that may shift, the
//! walker obtains offsets from a table that is verified against live
//! disassembly of MTGA's `mono-2.0-bdwgc.dll` — see the
//! `mono-memory-reader` skill for the verification recipe.
//!
//! `MonoOffsets::mtga_default()` returns the verified offset table
//! for the 2026-04-25 reading of MTGA's build (file timestamp
//! `Fri Apr 11 17:22:20 2025`). Every offset has been cross-checked
//! by the `offsets_probe/dump.c` program plus live disassembly. See
//! the [`OffsetKey`] enum for per-variant evidence citations.

/// Size of a pointer on the target process's architecture. Only x86-64
/// is supported.
pub const POINTER_SIZE: usize = 8;

/// Size of a single `MonoClassField` entry on Unity MBE / MSVC x86-64.
/// Verified by `offsets_probe/dump.c` printing `sizeof(MonoClassField)`
/// on 2026-04-25.
pub const MONO_CLASS_FIELD_SIZE: usize = 32;

/// Bytes to read for each `MonoClassDef` blob the walker consumes.
/// Must cover:
/// - `MonoClass.runtime_info` @ `0xd0`
/// - `MonoClass.vtable_size`  @ `0x5c`
/// - `MonoClass.fields`       @ `0x98`
/// - `MonoClassDef.field_count` @ `0x100`
///
/// 0x110 is the smallest power-of-16 size that covers all four.
pub const CLASS_DEF_BLOB_LEN: usize = 0x110;

/// Size of one `Dictionary<int, int>.Entry` struct on .NET reference
/// types: `(hashCode: i32, next: i32, key: i32, value: i32)` — four
/// 32-bit words.
pub const DICT_INT_INT_ENTRY_SIZE: usize = 16;

/// ECMA-335 `FIELD_ATTRIBUTE_STATIC` flag — set on a field's `type`
/// to mark it as a static field rather than an instance field. Used
/// by the walker to dispatch between `vtable->data[offset]` (static)
/// and `obj_ptr + offset` (instance) reads.
pub const MONO_FIELD_ATTR_STATIC: u16 = 0x10;

/// Table of struct offsets the walker uses. Constructed per build; see
/// [`MonoOffsets::mtga_default`] for verified values on MTGA's
/// 2026-04-25 build.
///
/// Field names mirror Mono's header-struct paths verbatim
/// (`gslist_*`, `aname_*`, etc. are not abbreviations — they're the
/// names Mono itself uses).
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct MonoOffsets {
    /// `MonoClass.fields` (pointer to `MonoClassField` array).
    /// Verified at `0x98`: matches `[rdi+0x98]` load in
    /// `mono_class_get_field_from_name`.
    pub class_fields: usize,
    /// `MonoClass.runtime_info` (pointer to `MonoClassRuntimeInfo`).
    /// Verified at `0xd0`: matches `mov rsi,[rdi+0xd0]` in
    /// `mono_class_vtable`'s non-failure path.
    pub class_runtime_info: usize,
    /// `MonoClass` flags bitfield cluster (one u32 covering
    /// `packing_size`, `ghcimpl`, `has_finalize`, `delegate`, …,
    /// `has_failure` at bit 20). Verified at `0x28`: matches
    /// `test dword [rdi+0x28], 0x100000` (the `has_failure` check)
    /// in `mono_class_vtable`.
    pub class_flags_cluster: usize,
    /// `MonoClassDef.field_count` (u32). Verified at `0x100` from the
    /// start of the enclosing `MonoClassDef` (which embeds `MonoClass`
    /// at offset 0). Only valid when `MonoClass.class_kind` indicates
    /// a `MonoClassDef`-shaped layout.
    pub class_def_field_count: usize,
    /// `MonoClassField.type` (`MonoType *`). Offset `0x00`.
    pub field_type: usize,
    /// `MonoClassField.name` (`const char *`). Offset `0x08`.
    pub field_name: usize,
    /// `MonoClassField.parent` (`MonoClass *`). Offset `0x10`.
    pub field_parent: usize,
    /// `MonoClassField.offset` (i32 — instance byte offset or static
    /// offset into the vtable's static storage). Offset `0x18`.
    pub field_offset: usize,
    /// `MonoType.attrs` — the u32 bitfield word at offset `0x08` of
    /// `MonoType`. Low 16 bits are the ECMA-335 field-attribute flags
    /// ([`MONO_FIELD_ATTR_STATIC`] = 0x10, etc.); bits 16-23 are
    /// `MonoTypeEnum type`; bits 24-26 are `has_cmods / byref /
    /// pinned`.
    pub type_attrs: usize,
    /// `MonoArray.max_length` — `uintptr_t` capacity of the array.
    /// Offset `0x18` on MBE / MSVC x86-64.
    pub array_max_length: usize,
    /// `MonoArray.vector` — start of element storage. Offset `0x20`.
    pub array_vector: usize,
    /// `MonoClass.vtable_size` (i32, slot count). Verified at `0x5c`.
    /// The static-storage pointer lives at `vtable[vtable_size]` —
    /// i.e. at the end of `MonoVTable`'s flexible method-slot array.
    pub class_vtable_size: usize,
    /// `MonoDomain.domain_id` (i32). Verified at `0x94`:
    /// `movsxd rcx,[r14+0x94]` in `mono_class_vtable`'s fast path.
    pub domain_id: usize,
    /// `MonoClassRuntimeInfo.max_domain` (u16). Offset `0x00` — first
    /// field of the struct, verified by `movzx eax, WORD PTR [rsi]`
    /// bounds check in `mono_class_vtable`.
    pub runtime_info_max_domain: usize,
    /// `MonoClassRuntimeInfo.domain_vtables` — start of the
    /// `MonoVTable *` array indexed by `domain_id`. Verified at
    /// `0x08`: `[rsi+rcx*8+0x8]` load in `mono_class_vtable`.
    pub runtime_info_domain_vtables: usize,
    /// `MonoVTable.vtable` — start of the flexible method-slot array.
    /// Verified at `0x48` (end of the fixed header fields). The
    /// static-storage slot lives at
    /// `vtable_method_slots + vtable_size * 8`.
    pub vtable_method_slots: usize,
    /// `MonoDomain.domain_assemblies` (`GSList *` head). Verified at
    /// `0xa0`: `mov r14,[r13+0xa0]` in
    /// `mono_domain_assembly_open_internal`, plus source order from
    /// `domain-internals.h`.
    pub domain_assemblies: usize,
    /// `GSList.data` (gpointer to the node's payload — a
    /// `MonoAssembly *` when iterating `domain_assemblies`).
    /// Offset `0x00`: `mov rsi,[r14]` against the GSList head reload
    /// in `mono_domain_assembly_open_internal`.
    pub gslist_data: usize,
    /// `GSList.next` (pointer to the next node, or NULL at the end of
    /// the list). Offset `0x08`: `mov r14,[r14+0x8]` in the same loop.
    pub gslist_next: usize,
    /// `MonoAssembly.aname.name` — the assembly short name. Composite
    /// offset: `aname` lives at `MonoAssembly+0x10` and its first
    /// field is `name` (a `const char *`), so reading `[asm+0x10]`
    /// yields the name pointer directly. Verified by
    /// `mov rax,[rbx+0x10]` in `mono_domain_assembly_open_internal`.
    pub assembly_aname_name: usize,
    /// `MonoAssembly.image` (`MonoImage *`). Verified at `0x60`:
    /// `mov rsi,[rsi+0x60]` reading the image pointer after
    /// dereferencing a GSList node's data slot.
    pub assembly_image: usize,
    /// `MonoClass.name` (`const char *`). Verified at `0x48` by
    /// `offsets_probe/dump.c`.
    pub class_name: usize,
    /// `MonoClass.parent` (`MonoClass *` to the base class, or `NULL`
    /// for `System.Object`). Verified at `0x30` by the existing
    /// match-manager spike's `dump_class_chain` walk.
    pub class_parent: usize,
    /// `MonoImage.class_cache` — start of the embedded
    /// `MonoInternalHashTable`. Verified at `0x4d0`:
    /// `lea rcx, [r13+0x4d0]; call mono_internal_hash_table_lookup`.
    pub image_class_cache: usize,
    /// `MonoInternalHashTable.size` (i32, bucket count). Verified at
    /// `0x18`: `div DWORD PTR [rdi+0x18]` in
    /// `mono_internal_hash_table_lookup`.
    pub hash_table_size: usize,
    /// `MonoInternalHashTable.num_entries` (i32). Offset `0x1c` per
    /// dumper.
    pub hash_table_num_entries: usize,
    /// `MonoInternalHashTable.table` (`gpointer *` — heap-allocated
    /// array of `size` chain heads). Verified at `0x20`:
    /// `mov rbx, [rdi+0x20]` in `mono_internal_hash_table_lookup`.
    pub hash_table_table: usize,
    /// `MonoClassDef.next_class_cache` — chain pointer for entries in
    /// `MonoImage.class_cache`. Offset `0x108` per `offsets_probe/`
    /// dumper.
    pub class_def_next_class_cache: usize,
}

impl MonoOffsets {
    /// Verified offsets for MTGA's `mono-2.0-bdwgc.dll` as of the
    /// 2026-04-25 reading (file timestamp `Fri Apr 11 17:22:20 2025`).
    /// Cross-checked by:
    /// 1. The `offsets_probe/` C dumper compiled with
    ///    `gcc -mms-bitfields` against the Unity `unity-2022.3-mbe`
    ///    headers.
    /// 2. Live disassembly of `mono_class_get_field_from_name`,
    ///    `mono_class_vtable`, and the non-failure path branch of the
    ///    latter.
    ///
    /// See the `mono-memory-reader` skill for per-field evidence and
    /// the re-verification recipe for new MTGA builds.
    pub const fn mtga_default() -> Self {
        Self {
            class_fields: 0x98,
            class_runtime_info: 0xd0,
            class_flags_cluster: 0x28,
            class_def_field_count: 0x100,
            field_type: 0x00,
            field_name: 0x08,
            field_parent: 0x10,
            field_offset: 0x18,
            type_attrs: 0x08,
            array_max_length: 0x18,
            array_vector: 0x20,
            class_vtable_size: 0x5c,
            domain_id: 0x94,
            runtime_info_max_domain: 0x00,
            runtime_info_domain_vtables: 0x08,
            vtable_method_slots: 0x48,
            domain_assemblies: 0xa0,
            gslist_data: 0x00,
            gslist_next: 0x08,
            assembly_aname_name: 0x10,
            assembly_image: 0x60,
            class_name: 0x48,
            class_parent: 0x30,
            image_class_cache: 0x4d0,
            hash_table_size: 0x18,
            hash_table_num_entries: 0x1c,
            hash_table_table: 0x20,
            class_def_next_class_cache: 0x108,
        }
    }
}

/// Little-endian `u8` read. Returns `None` if `base + offset` is out
/// of bounds.
pub fn read_u8(bytes: &[u8], base: usize, offset: usize) -> Option<u8> {
    let addr = base.checked_add(offset)?;
    bytes.get(addr).copied()
}

/// Little-endian `u16` read. Returns `None` on out-of-bounds or
/// arithmetic overflow.
pub fn read_u16(bytes: &[u8], base: usize, offset: usize) -> Option<u16> {
    let addr = base.checked_add(offset)?;
    let end = addr.checked_add(2)?;
    let slice = bytes.get(addr..end)?;
    Some(u16::from_le_bytes([slice[0], slice[1]]))
}

/// Little-endian `u32` read. Returns `None` on out-of-bounds or
/// arithmetic overflow.
pub fn read_u32(bytes: &[u8], base: usize, offset: usize) -> Option<u32> {
    let addr = base.checked_add(offset)?;
    let end = addr.checked_add(4)?;
    let slice = bytes.get(addr..end)?;
    Some(u32::from_le_bytes([slice[0], slice[1], slice[2], slice[3]]))
}

/// Little-endian `u64` read. Returns `None` on out-of-bounds or
/// arithmetic overflow.
pub fn read_u64(bytes: &[u8], base: usize, offset: usize) -> Option<u64> {
    let addr = base.checked_add(offset)?;
    let end = addr.checked_add(8)?;
    let slice = bytes.get(addr..end)?;
    Some(u64::from_le_bytes([
        slice[0], slice[1], slice[2], slice[3], slice[4], slice[5], slice[6], slice[7],
    ]))
}

/// Read a pointer-sized value. Equivalent to `read_u64` on x86-64.
pub fn read_ptr(bytes: &[u8], base: usize, offset: usize) -> Option<u64> {
    read_u64(bytes, base, offset)
}

/// Read `MonoClass.fields` — the pointer to the `MonoClassField` array
/// on a `MonoClass` at `class_base` inside `bytes`.
pub fn class_fields_ptr(offsets: &MonoOffsets, bytes: &[u8], class_base: usize) -> Option<u64> {
    read_ptr(bytes, class_base, offsets.class_fields)
}

/// Read `MonoClass.parent` — the pointer to the base class, or
/// `Some(0)` for `System.Object` (no parent). Returns `None` only on
/// out-of-bounds / arithmetic overflow.
pub fn class_parent_ptr(offsets: &MonoOffsets, bytes: &[u8], class_base: usize) -> Option<u64> {
    read_ptr(bytes, class_base, offsets.class_parent)
}

/// Read `MonoClass.runtime_info` — the pointer to the
/// `MonoClassRuntimeInfo` on a `MonoClass` at `class_base`.
pub fn class_runtime_info_ptr(
    offsets: &MonoOffsets,
    bytes: &[u8],
    class_base: usize,
) -> Option<u64> {
    read_ptr(bytes, class_base, offsets.class_runtime_info)
}

/// Read the 32-bit flags cluster at `MonoClass + class_flags_cluster`.
/// The caller masks individual flag bits.
pub fn class_flags_cluster(offsets: &MonoOffsets, bytes: &[u8], class_base: usize) -> Option<u32> {
    read_u32(bytes, class_base, offsets.class_flags_cluster)
}

/// Read `MonoClassDef.field_count` from a `MonoClassDef`-shaped block
/// at `class_base`. Callers must confirm `MonoClass.class_kind`
/// indicates a `MonoClassDef` (`class_kind == 1`) before relying on
/// this value — other `class_kind`s use different layouts.
pub fn class_def_field_count(
    offsets: &MonoOffsets,
    bytes: &[u8],
    class_base: usize,
) -> Option<u32> {
    read_u32(bytes, class_base, offsets.class_def_field_count)
}

/// Compute the byte base of the `n`-th `MonoClassField` within a
/// contiguous `MonoClassField[]` at `fields_array_base`. Returns
/// `None` on usize overflow.
pub fn class_field_entry_base(fields_array_base: usize, n: usize) -> Option<usize> {
    n.checked_mul(MONO_CLASS_FIELD_SIZE)
        .and_then(|step| fields_array_base.checked_add(step))
}

/// Read `MonoClassField.type` (`MonoType *`) for a field entry whose
/// byte position inside `bytes` is `field_base`.
pub fn field_type_ptr(offsets: &MonoOffsets, bytes: &[u8], field_base: usize) -> Option<u64> {
    read_ptr(bytes, field_base, offsets.field_type)
}

/// Read `MonoClassField.name` (a `const char *` in the target
/// process). The returned `u64` is the remote address of the
/// null-terminated name; the walker uses a process-memory reader to
/// pull the actual bytes.
pub fn field_name_ptr(offsets: &MonoOffsets, bytes: &[u8], field_base: usize) -> Option<u64> {
    read_ptr(bytes, field_base, offsets.field_name)
}

/// Read `MonoClassField.parent` (`MonoClass *` — the declaring class).
pub fn field_parent_ptr(offsets: &MonoOffsets, bytes: &[u8], field_base: usize) -> Option<u64> {
    read_ptr(bytes, field_base, offsets.field_parent)
}

/// Read `MonoClassField.offset` (signed, as mono uses -1 during vtable
/// construction for special-static fields).
pub fn field_offset_value(offsets: &MonoOffsets, bytes: &[u8], field_base: usize) -> Option<i32> {
    read_u32(bytes, field_base, offsets.field_offset).map(|v| v as i32)
}

/// Read the low-16-bit `attrs` portion of `MonoType` at `type_base`.
/// The returned value is the ECMA-335 field-attribute bitmap —
/// mask with [`MONO_FIELD_ATTR_STATIC`] to check static vs instance.
pub fn type_attrs(offsets: &MonoOffsets, bytes: &[u8], type_base: usize) -> Option<u16> {
    read_u32(bytes, type_base, offsets.type_attrs).map(|v| (v & 0xffff) as u16)
}

/// Return `true` if the given attrs bitmap has `MONO_FIELD_ATTR_STATIC`
/// set.
pub fn attrs_is_static(attrs: u16) -> bool {
    attrs & MONO_FIELD_ATTR_STATIC != 0
}

/// Read `MonoArray.max_length` (capacity) from a `MonoArray` at
/// `array_base`. The value is a `uintptr_t` on the target
/// architecture — an `u64` on x86-64.
pub fn array_max_length(offsets: &MonoOffsets, bytes: &[u8], array_base: usize) -> Option<u64> {
    read_u64(bytes, array_base, offsets.array_max_length)
}

/// Return the remote address of the first element slot of a
/// `MonoArray` whose object base (in the target process) is
/// `array_remote_addr`. This is `array_remote_addr + array_vector`.
pub fn array_vector_addr(offsets: &MonoOffsets, array_remote_addr: u64) -> Option<u64> {
    array_remote_addr.checked_add(offsets.array_vector as u64)
}

/// Decode a `MonoString` at `str_addr` into a Rust `String`.
///
/// Layout: `vtable(8) + sync(8) + length:i32 + chars[length]` where
/// `chars` is UTF-16 LE and `length` is the code-unit count.
///
/// Returns `None` when:
/// - `str_addr` is null (caller likely already checked, but we re-check),
/// - the header is unreadable or short,
/// - `length` exceeds `max_chars` (sanity guard against torn reads —
///   pass 1024 for screen names, larger for free-form text), or
/// - the chars blob is unreadable / not valid UTF-16.
///
/// Returns `Some("")` for a valid zero-length string.
pub fn read_mono_string<F>(str_addr: u64, max_chars: usize, read_mem: &F) -> Option<String>
where
    F: Fn(u64, usize) -> Option<Vec<u8>>,
{
    if str_addr == 0 {
        return None;
    }
    let header = read_mem(str_addr, MONO_STRING_HEADER_LEN)?;
    if header.len() < MONO_STRING_HEADER_LEN {
        return None;
    }
    let length = i32::from_le_bytes([
        header[MONO_STRING_LENGTH_OFFSET],
        header[MONO_STRING_LENGTH_OFFSET + 1],
        header[MONO_STRING_LENGTH_OFFSET + 2],
        header[MONO_STRING_LENGTH_OFFSET + 3],
    ])
    .max(0) as usize;
    if length == 0 {
        return Some(String::new());
    }
    if length > max_chars {
        return None;
    }
    let chars_addr = str_addr.checked_add(MONO_STRING_CHARS_OFFSET as u64)?;
    let chars_bytes = read_mem(chars_addr, length.checked_mul(2)?)?;
    if chars_bytes.len() < length * 2 {
        return None;
    }
    let utf16: Vec<u16> = chars_bytes
        .chunks_exact(2)
        .map(|c| u16::from_le_bytes([c[0], c[1]]))
        .collect();
    String::from_utf16(&utf16).ok()
}

/// `MonoString.length` lives at offset `0x10` (after `vtable` and `sync`).
const MONO_STRING_LENGTH_OFFSET: usize = 0x10;
/// `MonoString` header length — `vtable + sync + length:i32`.
const MONO_STRING_HEADER_LEN: usize = 0x14;
/// First UTF-16 code unit of a `MonoString` lives at `0x14`.
const MONO_STRING_CHARS_OFFSET: usize = 0x14;

/// Read `MonoClass.vtable_size` (i32 number of method slots) at
/// `class_base`.
pub fn class_vtable_size(offsets: &MonoOffsets, bytes: &[u8], class_base: usize) -> Option<i32> {
    read_u32(bytes, class_base, offsets.class_vtable_size).map(|v| v as i32)
}

/// Read `MonoDomain.domain_id` (i32) at `domain_base`.
pub fn domain_id(offsets: &MonoOffsets, bytes: &[u8], domain_base: usize) -> Option<i32> {
    read_u32(bytes, domain_base, offsets.domain_id).map(|v| v as i32)
}

/// Read `MonoClassRuntimeInfo.max_domain` (u16) at `rti_base`.
pub fn runtime_info_max_domain(
    offsets: &MonoOffsets,
    bytes: &[u8],
    rti_base: usize,
) -> Option<u16> {
    read_u16(bytes, rti_base, offsets.runtime_info_max_domain)
}

/// Compute the remote address of `domain_vtables[domain_id]` within
/// a `MonoClassRuntimeInfo` at `rti_remote_addr`. Caller verifies
/// `domain_id` is within bounds via [`runtime_info_max_domain`] first.
pub fn runtime_info_domain_vtable_addr(
    offsets: &MonoOffsets,
    rti_remote_addr: u64,
    domain_id: u32,
) -> Option<u64> {
    let slot_offset = (domain_id as u64).checked_mul(POINTER_SIZE as u64)?;
    rti_remote_addr
        .checked_add(offsets.runtime_info_domain_vtables as u64)?
        .checked_add(slot_offset)
}

/// Compute the remote address of the static-storage slot within a
/// `MonoVTable` at `vtable_remote_addr`, given the class's
/// `vtable_size` (method slot count). The static-storage pointer
/// lives at `vtable + vtable_method_slots + vtable_size * 8` — i.e.
/// just past the flexible method-slot array.
pub fn vtable_static_slot_addr(
    offsets: &MonoOffsets,
    vtable_remote_addr: u64,
    vtable_size: u32,
) -> Option<u64> {
    let slot_off = (vtable_size as u64).checked_mul(POINTER_SIZE as u64)?;
    vtable_remote_addr
        .checked_add(offsets.vtable_method_slots as u64)?
        .checked_add(slot_off)
}

/// Read `MonoDomain.domain_assemblies` — the head pointer of the
/// `GSList` of loaded `MonoAssembly *` for this domain. Returns
/// `None` on out-of-bounds; a successful read of 0 means the list
/// is empty.
pub fn domain_assemblies_ptr(
    offsets: &MonoOffsets,
    bytes: &[u8],
    domain_base: usize,
) -> Option<u64> {
    read_ptr(bytes, domain_base, offsets.domain_assemblies)
}

/// Read `GSList.data` — the payload pointer at the given list node.
pub fn gslist_data_ptr(offsets: &MonoOffsets, bytes: &[u8], node_base: usize) -> Option<u64> {
    read_ptr(bytes, node_base, offsets.gslist_data)
}

/// Read `GSList.next` — the pointer to the next node, or 0 at the
/// end of the list.
pub fn gslist_next_ptr(offsets: &MonoOffsets, bytes: &[u8], node_base: usize) -> Option<u64> {
    read_ptr(bytes, node_base, offsets.gslist_next)
}

/// Read `MonoAssembly.aname.name` — the assembly's short name as a
/// remote `const char *`. The walker uses a process-memory reader
/// to pull the actual NUL-terminated bytes.
pub fn assembly_aname_name_ptr(
    offsets: &MonoOffsets,
    bytes: &[u8],
    assembly_base: usize,
) -> Option<u64> {
    read_ptr(bytes, assembly_base, offsets.assembly_aname_name)
}

/// Read `MonoAssembly.image` — the `MonoImage *` for this assembly.
pub fn assembly_image_ptr(
    offsets: &MonoOffsets,
    bytes: &[u8],
    assembly_base: usize,
) -> Option<u64> {
    read_ptr(bytes, assembly_base, offsets.assembly_image)
}

/// Read `MonoClass.name` — pointer to the class's NUL-terminated
/// short name in the target process.
pub fn class_name_ptr(offsets: &MonoOffsets, bytes: &[u8], class_base: usize) -> Option<u64> {
    read_ptr(bytes, class_base, offsets.class_name)
}

/// Compute the remote address of `MonoImage.class_cache` (the start
/// of the embedded `MonoInternalHashTable`) given the image's remote
/// address.
pub fn image_class_cache_addr(offsets: &MonoOffsets, image_remote_addr: u64) -> Option<u64> {
    image_remote_addr.checked_add(offsets.image_class_cache as u64)
}

/// Read `MonoInternalHashTable.size` (i32 — bucket count).
pub fn hash_table_size(offsets: &MonoOffsets, bytes: &[u8], table_base: usize) -> Option<i32> {
    read_u32(bytes, table_base, offsets.hash_table_size).map(|v| v as i32)
}

/// Read `MonoInternalHashTable.num_entries` (i32). Useful as a
/// sanity / diagnostic counter; the walker doesn't rely on it for
/// iteration.
pub fn hash_table_num_entries(
    offsets: &MonoOffsets,
    bytes: &[u8],
    table_base: usize,
) -> Option<i32> {
    read_u32(bytes, table_base, offsets.hash_table_num_entries).map(|v| v as i32)
}

/// Read `MonoInternalHashTable.table` — pointer to the heap-allocated
/// `gpointer[size]` array of bucket-chain heads.
pub fn hash_table_table_ptr(offsets: &MonoOffsets, bytes: &[u8], table_base: usize) -> Option<u64> {
    read_ptr(bytes, table_base, offsets.hash_table_table)
}

/// Read `MonoClassDef.next_class_cache` — the chain pointer in
/// `MonoImage.class_cache` buckets. Each value is a `MonoClass *`
/// (the next entry in the same bucket) or 0 at the end.
pub fn class_def_next_class_cache_ptr(
    offsets: &MonoOffsets,
    bytes: &[u8],
    class_base: usize,
) -> Option<u64> {
    read_ptr(bytes, class_base, offsets.class_def_next_class_cache)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn buf_with(value_at: usize, bytes_to_write: &[u8]) -> Vec<u8> {
        let mut v = vec![0u8; value_at + bytes_to_write.len() + 16];
        v[value_at..value_at + bytes_to_write.len()].copy_from_slice(bytes_to_write);
        v
    }

    #[test]
    fn read_u8_returns_value_at_offset() {
        let buf = buf_with(0x20, &[0x7f]);
        assert_eq!(read_u8(&buf, 0x10, 0x10), Some(0x7f));
    }

    #[test]
    fn read_u8_out_of_bounds_is_none() {
        let buf = vec![0u8; 4];
        assert_eq!(read_u8(&buf, 0, 4), None);
    }

    #[test]
    fn read_u16_little_endian() {
        let buf = buf_with(0x10, &[0x34, 0x12]);
        assert_eq!(read_u16(&buf, 0x10, 0), Some(0x1234));
    }

    #[test]
    fn read_u32_little_endian() {
        let buf = buf_with(0x10, &[0x78, 0x56, 0x34, 0x12]);
        assert_eq!(read_u32(&buf, 0x10, 0), Some(0x1234_5678));
    }

    #[test]
    fn read_u32_truncated_is_none() {
        let buf = vec![0u8; 0x12];
        assert_eq!(read_u32(&buf, 0x10, 0), None);
    }

    #[test]
    fn read_u64_little_endian() {
        let buf = buf_with(0, &[0xef, 0xcd, 0xab, 0x89, 0x67, 0x45, 0x23, 0x01]);
        assert_eq!(read_u64(&buf, 0, 0), Some(0x0123_4567_89ab_cdef));
    }

    #[test]
    fn read_ptr_is_u64() {
        let buf = buf_with(0, &[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7f, 0x00]);
        assert_eq!(read_ptr(&buf, 0, 0), Some(0x007f_0000_0000_0000));
    }

    #[test]
    fn read_ptr_respects_base_plus_offset() {
        // Place the pointer at 0x40, then query via base=0x20, offset=0x20.
        let ptr: u64 = 0xdead_beef_cafe_babe;
        let buf = buf_with(0x40, &ptr.to_le_bytes());
        assert_eq!(read_ptr(&buf, 0x20, 0x20), Some(ptr));
    }

    #[test]
    fn read_ptr_arithmetic_overflow_is_none() {
        let buf = vec![0u8; 8];
        assert_eq!(read_ptr(&buf, usize::MAX, 1), None);
    }

    #[test]
    fn mtga_default_matches_verified_offsets() {
        // Locks the verified values so an accidental change is caught.
        // Update this test together with the skill file (and re-run the
        // offsets_probe dumper) before any offset change ships.
        let offsets = MonoOffsets::mtga_default();
        assert_eq!(offsets.class_fields, 0x98);
        assert_eq!(offsets.class_runtime_info, 0xd0);
        assert_eq!(offsets.class_flags_cluster, 0x28);
        assert_eq!(offsets.class_def_field_count, 0x100);
        assert_eq!(offsets.field_type, 0x00);
        assert_eq!(offsets.field_name, 0x08);
        assert_eq!(offsets.field_parent, 0x10);
        assert_eq!(offsets.field_offset, 0x18);
        assert_eq!(offsets.type_attrs, 0x08);
        assert_eq!(offsets.array_max_length, 0x18);
        assert_eq!(offsets.array_vector, 0x20);
        assert_eq!(offsets.class_vtable_size, 0x5c);
        assert_eq!(offsets.domain_id, 0x94);
        assert_eq!(offsets.runtime_info_max_domain, 0x00);
        assert_eq!(offsets.runtime_info_domain_vtables, 0x08);
        assert_eq!(offsets.vtable_method_slots, 0x48);
        assert_eq!(offsets.domain_assemblies, 0xa0);
        assert_eq!(offsets.gslist_data, 0x00);
        assert_eq!(offsets.gslist_next, 0x08);
        assert_eq!(offsets.assembly_aname_name, 0x10);
        assert_eq!(offsets.assembly_image, 0x60);
        assert_eq!(offsets.class_name, 0x48);
        assert_eq!(offsets.image_class_cache, 0x4d0);
        assert_eq!(offsets.hash_table_size, 0x18);
        assert_eq!(offsets.hash_table_num_entries, 0x1c);
        assert_eq!(offsets.hash_table_table, 0x20);
        assert_eq!(offsets.class_def_next_class_cache, 0x108);
    }

    #[test]
    fn dict_entry_size_is_16() {
        assert_eq!(DICT_INT_INT_ENTRY_SIZE, 16);
    }

    #[test]
    fn mono_class_field_size_is_32() {
        assert_eq!(MONO_CLASS_FIELD_SIZE, 32);
    }

    #[test]
    fn class_fields_ptr_reads_at_correct_offset() {
        let offsets = MonoOffsets::mtga_default();
        let klass_base = 0x100;
        let fields_ptr: u64 = 0x7fff_1234_5670;
        let mut buf = vec![0u8; klass_base + 0x200];
        buf[klass_base + offsets.class_fields..klass_base + offsets.class_fields + 8]
            .copy_from_slice(&fields_ptr.to_le_bytes());
        assert_eq!(
            class_fields_ptr(&offsets, &buf, klass_base),
            Some(fields_ptr)
        );
    }

    #[test]
    fn class_runtime_info_ptr_reads_at_correct_offset() {
        let offsets = MonoOffsets::mtga_default();
        let klass_base = 0x40;
        let rti_ptr: u64 = 0x55aa_55aa_55aa_55aa;
        let mut buf = vec![0u8; klass_base + 0x200];
        buf[klass_base + offsets.class_runtime_info..klass_base + offsets.class_runtime_info + 8]
            .copy_from_slice(&rti_ptr.to_le_bytes());
        assert_eq!(
            class_runtime_info_ptr(&offsets, &buf, klass_base),
            Some(rti_ptr)
        );
    }

    #[test]
    fn class_flags_cluster_reads_32_bit_value() {
        let offsets = MonoOffsets::mtga_default();
        let klass_base = 0x0;
        let flags: u32 = 0x0010_0040; // bit 20 set, plus some low bits
        let mut buf = vec![0u8; 0x100];
        buf[klass_base + offsets.class_flags_cluster..klass_base + offsets.class_flags_cluster + 4]
            .copy_from_slice(&flags.to_le_bytes());
        let read = class_flags_cluster(&offsets, &buf, klass_base);
        assert_eq!(read, Some(flags));
        // Caller typically masks bit 20 (e.g. a MonoClass kind check).
        assert_eq!(read.map(|v| v & 0x0010_0000), Some(0x0010_0000));
    }

    #[test]
    fn accessors_return_none_on_truncated_buffer() {
        let offsets = MonoOffsets::mtga_default();
        let buf = vec![0u8; 0x20]; // too small for any offset above 0x1c
        assert_eq!(class_fields_ptr(&offsets, &buf, 0), None);
        assert_eq!(class_runtime_info_ptr(&offsets, &buf, 0), None);
        // flags cluster fits (0x28 + 4 > 0x20 so still None):
        assert_eq!(class_flags_cluster(&offsets, &buf, 0), None);
    }

    #[test]
    fn class_def_field_count_reads_at_0x100() {
        let offsets = MonoOffsets::mtga_default();
        let class_base = 0x40;
        let count: u32 = 7;
        let mut buf = vec![0u8; class_base + 0x200];
        buf[class_base + offsets.class_def_field_count
            ..class_base + offsets.class_def_field_count + 4]
            .copy_from_slice(&count.to_le_bytes());
        assert_eq!(class_def_field_count(&offsets, &buf, class_base), Some(7));
    }

    #[test]
    fn class_field_entry_base_steps_by_32_bytes() {
        // Contiguous array starting at some fictitious remote addr;
        // this helper is arithmetic-only so it works fine with any base.
        assert_eq!(class_field_entry_base(0x1000, 0), Some(0x1000));
        assert_eq!(class_field_entry_base(0x1000, 1), Some(0x1020));
        assert_eq!(class_field_entry_base(0x1000, 2), Some(0x1040));
        assert_eq!(class_field_entry_base(0x1000, 100), Some(0x1000 + 32 * 100));
    }

    #[test]
    fn class_field_entry_base_rejects_overflow() {
        assert_eq!(class_field_entry_base(usize::MAX - 1, 1), None);
        assert_eq!(class_field_entry_base(0, usize::MAX), None);
    }

    /// Write a 32-byte MonoClassField entry at `field_base` inside `buf`.
    fn write_field_entry(
        buf: &mut [u8],
        field_base: usize,
        type_ptr: u64,
        name_ptr: u64,
        parent_ptr: u64,
        offset: i32,
    ) {
        let o = MonoOffsets::mtga_default();
        buf[field_base + o.field_type..field_base + o.field_type + 8]
            .copy_from_slice(&type_ptr.to_le_bytes());
        buf[field_base + o.field_name..field_base + o.field_name + 8]
            .copy_from_slice(&name_ptr.to_le_bytes());
        buf[field_base + o.field_parent..field_base + o.field_parent + 8]
            .copy_from_slice(&parent_ptr.to_le_bytes());
        buf[field_base + o.field_offset..field_base + o.field_offset + 4]
            .copy_from_slice(&(offset as u32).to_le_bytes());
    }

    #[test]
    fn field_accessors_read_all_four_members() {
        let offsets = MonoOffsets::mtga_default();
        let mut buf = vec![0u8; 0x100];
        let field_base = 0x20;
        let type_ptr = 0x1111_2222_3333_4444_u64;
        let name_ptr = 0x5555_6666_7777_8888_u64;
        let parent_ptr = 0x9999_aaaa_bbbb_cccc_u64;
        let offset: i32 = 0x30;
        write_field_entry(&mut buf, field_base, type_ptr, name_ptr, parent_ptr, offset);

        assert_eq!(field_type_ptr(&offsets, &buf, field_base), Some(type_ptr));
        assert_eq!(field_name_ptr(&offsets, &buf, field_base), Some(name_ptr));
        assert_eq!(
            field_parent_ptr(&offsets, &buf, field_base),
            Some(parent_ptr)
        );
        assert_eq!(field_offset_value(&offsets, &buf, field_base), Some(offset));
    }

    #[test]
    fn field_offset_value_preserves_negative_sentinel() {
        // Mono uses -1 during vtable construction for special-static
        // fields. Confirm the i32 sign is preserved through the u32
        // intermediate read.
        let offsets = MonoOffsets::mtga_default();
        let mut buf = vec![0u8; 0x40];
        write_field_entry(&mut buf, 0, 0, 0, 0, -1);
        assert_eq!(field_offset_value(&offsets, &buf, 0), Some(-1));
    }

    #[test]
    fn field_accessors_return_none_on_truncated_buffer() {
        let offsets = MonoOffsets::mtga_default();
        let buf = vec![0u8; 0x10]; // too small for offset field at +0x18
        assert_eq!(field_offset_value(&offsets, &buf, 0), None);
        // name ptr needs up to +0x10 (8 bytes from offset 8), buf has 16 bytes
        // — matches exactly, so the read should succeed:
        assert_eq!(field_name_ptr(&offsets, &buf, 0), Some(0));
        // parent ptr needs up to +0x18 — OOB:
        assert_eq!(field_parent_ptr(&offsets, &buf, 0), None);
    }

    #[test]
    fn type_attrs_masks_low_16_bits() {
        // MonoType layout: 8 bytes `data` union, then a u32 bitfield
        // cluster at offset 8. The low 16 bits are `attrs`; bits 16-26
        // carry the type enum, has_cmods, byref, pinned. The accessor
        // must ignore everything above bit 15.
        let offsets = MonoOffsets::mtga_default();
        let mut buf = vec![0u8; 0x20];
        let bitfield_word: u32 = 0x0300_0010; // high bits set, attrs = 0x10
        buf[8..12].copy_from_slice(&bitfield_word.to_le_bytes());
        assert_eq!(type_attrs(&offsets, &buf, 0), Some(0x0010));
    }

    #[test]
    fn attrs_is_static_detects_static_bit() {
        assert!(attrs_is_static(MONO_FIELD_ATTR_STATIC));
        assert!(attrs_is_static(MONO_FIELD_ATTR_STATIC | 0x0006));
        assert!(!attrs_is_static(0x0000));
        assert!(!attrs_is_static(0x000f)); // bits 0-3 set but not bit 4
    }

    #[test]
    fn array_max_length_reads_u64_at_0x18() {
        let offsets = MonoOffsets::mtga_default();
        let array_base = 0x200;
        let capacity: u64 = 0x20e3; // example from spike 7 POC (8419)
        let mut buf = vec![0u8; array_base + 0x100];
        buf[array_base + offsets.array_max_length..array_base + offsets.array_max_length + 8]
            .copy_from_slice(&capacity.to_le_bytes());
        assert_eq!(array_max_length(&offsets, &buf, array_base), Some(capacity));
    }

    #[test]
    fn array_vector_addr_steps_by_0x20() {
        let offsets = MonoOffsets::mtga_default();
        assert_eq!(
            array_vector_addr(&offsets, 0x1_0000_0000),
            Some(0x1_0000_0020)
        );
        assert_eq!(array_vector_addr(&offsets, 0), Some(0x20));
    }

    #[test]
    fn array_vector_addr_rejects_overflow() {
        let offsets = MonoOffsets::mtga_default();
        assert_eq!(array_vector_addr(&offsets, u64::MAX), None);
    }

    #[test]
    fn class_vtable_size_reads_i32_at_0x5c() {
        let offsets = MonoOffsets::mtga_default();
        let class_base = 0x40;
        let size: i32 = 17;
        let mut buf = vec![0u8; class_base + 0x110];
        buf[class_base + offsets.class_vtable_size..class_base + offsets.class_vtable_size + 4]
            .copy_from_slice(&(size as u32).to_le_bytes());
        assert_eq!(class_vtable_size(&offsets, &buf, class_base), Some(17));
    }

    #[test]
    fn domain_id_reads_i32_at_0x94() {
        let offsets = MonoOffsets::mtga_default();
        let domain_base = 0x80;
        let id: i32 = 3;
        let mut buf = vec![0u8; domain_base + 0x100];
        buf[domain_base + offsets.domain_id..domain_base + offsets.domain_id + 4]
            .copy_from_slice(&(id as u32).to_le_bytes());
        assert_eq!(domain_id(&offsets, &buf, domain_base), Some(3));
    }

    #[test]
    fn runtime_info_max_domain_reads_u16_at_0x00() {
        let offsets = MonoOffsets::mtga_default();
        let max: u16 = 7;
        let mut buf = vec![0u8; 0x20];
        buf[0..2].copy_from_slice(&max.to_le_bytes());
        assert_eq!(runtime_info_max_domain(&offsets, &buf, 0), Some(7));
    }

    #[test]
    fn runtime_info_domain_vtable_addr_indexes_by_pointer_size() {
        let offsets = MonoOffsets::mtga_default();
        let rti: u64 = 0x1_0000;
        // First slot: rti + 8
        assert_eq!(
            runtime_info_domain_vtable_addr(&offsets, rti, 0),
            Some(rti + 8)
        );
        // Third slot: rti + 8 + 2*8
        assert_eq!(
            runtime_info_domain_vtable_addr(&offsets, rti, 2),
            Some(rti + 8 + 16)
        );
    }

    #[test]
    fn vtable_static_slot_addr_points_past_method_slots() {
        let offsets = MonoOffsets::mtga_default();
        let vtable: u64 = 0x2_0000;
        // vtable_size = 0 → static slot at vtable + 0x48 (right after
        // the header, no method slots).
        assert_eq!(
            vtable_static_slot_addr(&offsets, vtable, 0),
            Some(vtable + 0x48)
        );
        // vtable_size = 5 → static slot at vtable + 0x48 + 5*8 = 0x70.
        assert_eq!(
            vtable_static_slot_addr(&offsets, vtable, 5),
            Some(vtable + 0x48 + 40)
        );
    }

    #[test]
    fn vtable_static_slot_addr_rejects_overflow() {
        let offsets = MonoOffsets::mtga_default();
        assert_eq!(vtable_static_slot_addr(&offsets, u64::MAX, 1), None);
    }

    #[test]
    fn domain_assemblies_ptr_reads_at_0xa0() {
        let offsets = MonoOffsets::mtga_default();
        let domain_base = 0x100;
        let head: u64 = 0x7fff_aaaa_bbbb_0000;
        let mut buf = vec![0u8; domain_base + 0x200];
        buf[domain_base + offsets.domain_assemblies..domain_base + offsets.domain_assemblies + 8]
            .copy_from_slice(&head.to_le_bytes());
        assert_eq!(
            domain_assemblies_ptr(&offsets, &buf, domain_base),
            Some(head)
        );
    }

    #[test]
    fn gslist_accessors_read_data_and_next() {
        let offsets = MonoOffsets::mtga_default();
        let node_base = 0x80;
        let data: u64 = 0x1111_2222_3333_4444;
        let next: u64 = 0x5555_6666_7777_8888;
        let mut buf = vec![0u8; node_base + 0x40];
        buf[node_base + offsets.gslist_data..node_base + offsets.gslist_data + 8]
            .copy_from_slice(&data.to_le_bytes());
        buf[node_base + offsets.gslist_next..node_base + offsets.gslist_next + 8]
            .copy_from_slice(&next.to_le_bytes());
        assert_eq!(gslist_data_ptr(&offsets, &buf, node_base), Some(data));
        assert_eq!(gslist_next_ptr(&offsets, &buf, node_base), Some(next));
    }

    #[test]
    fn gslist_next_zero_signals_end_of_list() {
        let offsets = MonoOffsets::mtga_default();
        let buf = vec![0u8; 0x20];
        assert_eq!(gslist_next_ptr(&offsets, &buf, 0), Some(0));
    }

    #[test]
    fn assembly_accessors_read_name_and_image() {
        let offsets = MonoOffsets::mtga_default();
        let asm_base = 0x40;
        let name_ptr: u64 = 0xaaaa_bbbb_cccc_dddd;
        let image_ptr: u64 = 0x1010_2020_3030_4040;
        let mut buf = vec![0u8; asm_base + 0x100];
        buf[asm_base + offsets.assembly_aname_name..asm_base + offsets.assembly_aname_name + 8]
            .copy_from_slice(&name_ptr.to_le_bytes());
        buf[asm_base + offsets.assembly_image..asm_base + offsets.assembly_image + 8]
            .copy_from_slice(&image_ptr.to_le_bytes());
        assert_eq!(
            assembly_aname_name_ptr(&offsets, &buf, asm_base),
            Some(name_ptr)
        );
        assert_eq!(
            assembly_image_ptr(&offsets, &buf, asm_base),
            Some(image_ptr)
        );
    }

    #[test]
    fn assembly_accessors_return_none_on_truncated_buffer() {
        let offsets = MonoOffsets::mtga_default();
        // Too small for `image` at 0x60 (needs 0x60 + 8 = 0x68 bytes).
        let buf = vec![0u8; 0x60];
        assert_eq!(assembly_image_ptr(&offsets, &buf, 0), None);
        // Just large enough for `aname.name` at 0x10:
        let small = vec![0u8; 0x18];
        assert_eq!(assembly_aname_name_ptr(&offsets, &small, 0), Some(0));
    }

    #[test]
    fn class_name_ptr_reads_at_0x48() {
        let offsets = MonoOffsets::mtga_default();
        let class_base = 0x40;
        let name_ptr: u64 = 0xdead_beef_0000_1234;
        let mut buf = vec![0u8; class_base + 0x100];
        buf[class_base + offsets.class_name..class_base + offsets.class_name + 8]
            .copy_from_slice(&name_ptr.to_le_bytes());
        assert_eq!(class_name_ptr(&offsets, &buf, class_base), Some(name_ptr));
    }

    #[test]
    fn image_class_cache_addr_offsets_by_0x4d0() {
        let offsets = MonoOffsets::mtga_default();
        let image: u64 = 0x1_0000_0000;
        assert_eq!(image_class_cache_addr(&offsets, image), Some(image + 0x4d0));
    }

    #[test]
    fn image_class_cache_addr_rejects_overflow() {
        let offsets = MonoOffsets::mtga_default();
        assert_eq!(image_class_cache_addr(&offsets, u64::MAX), None);
    }

    #[test]
    fn hash_table_accessors_read_size_num_entries_table() {
        let offsets = MonoOffsets::mtga_default();
        let table_base = 0x80;
        let size: i32 = 1024;
        let num: i32 = 837;
        let table_ptr: u64 = 0x7fff_aaaa_bbbb_cccc;
        let mut buf = vec![0u8; table_base + 0x40];
        buf[table_base + offsets.hash_table_size..table_base + offsets.hash_table_size + 4]
            .copy_from_slice(&(size as u32).to_le_bytes());
        buf[table_base + offsets.hash_table_num_entries
            ..table_base + offsets.hash_table_num_entries + 4]
            .copy_from_slice(&(num as u32).to_le_bytes());
        buf[table_base + offsets.hash_table_table..table_base + offsets.hash_table_table + 8]
            .copy_from_slice(&table_ptr.to_le_bytes());

        assert_eq!(hash_table_size(&offsets, &buf, table_base), Some(size));
        assert_eq!(
            hash_table_num_entries(&offsets, &buf, table_base),
            Some(num)
        );
        assert_eq!(
            hash_table_table_ptr(&offsets, &buf, table_base),
            Some(table_ptr)
        );
    }

    #[test]
    fn class_def_next_class_cache_reads_at_0x108() {
        let offsets = MonoOffsets::mtga_default();
        let class_base = 0x10;
        let next_ptr: u64 = 0xcafe_0011_2233_4455;
        let mut buf = vec![0u8; class_base + 0x200];
        buf[class_base + offsets.class_def_next_class_cache
            ..class_base + offsets.class_def_next_class_cache + 8]
            .copy_from_slice(&next_ptr.to_le_bytes());
        assert_eq!(
            class_def_next_class_cache_ptr(&offsets, &buf, class_base),
            Some(next_ptr)
        );
    }
}
