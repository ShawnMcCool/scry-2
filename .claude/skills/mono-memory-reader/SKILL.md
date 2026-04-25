---
name: mono-memory-reader
description: Use when working on Scry2.Collection's walker path — the Rust NIF crate under native/scry2_collection_reader that navigates MTGA's in-process Mono runtime. Covers the pointer chain, Mono struct offsets, PE/prologue decoding, and the canonical sources for cross-verification.
---

# MTGA Mono Memory Reader

Technical reference for the **walker path** of `Scry2.Collection`'s reader
(the Rust NIF crate at `native/scry2_collection_reader/`). The walker
resolves MTGA's live collection, wildcards, gold, gems, and vault progress
by walking named pointers through the process's Mono runtime.

For the fallback **structural-scan path**, see the POC at
`mtga-duress/experiments/mtga-reader-poc/`.

## MTGA runtime identity

| Property | Value |
|---|---|
| Engine | Unity 2022.3.62f2 (Proton/Wine on Linux) |
| Scripting backend | Mono (not IL2CPP) |
| Mono runtime DLL | `mono-2.0-bdwgc.dll` (MonoBleedingEdge) |
| Mono DLL on-disk | `$STEAM/common/MTGA/MonoBleedingEdge/EmbedRuntime/mono-2.0-bdwgc.dll` |
| Managed assemblies | `Core.dll`, `Assembly-CSharp.dll`, `SharedClientCore.dll` |
| PE layout | PE32+, `ImageBase = 0x180000000` |

MTGA's `mono-2.0-bdwgc.dll` on-disk and mapped bytes are byte-identical
across its read-only code sections. The disassembly below is derived from
the on-disk file; verification against live memory is a straight
`read_bytes` at the RVA.

## The pointer chain

From the Unity 2022.3.62f2 build, the walker navigates:

```
mono_get_root_domain()                  -> MonoDomain *
  (walk assemblies to Core.dll or Assembly-CSharp.dll)
  class PAPA
    <Instance>k__BackingField           (STATIC field — read via VTable)
      <InventoryManager>k__BackingField (instance)
        _inventoryServiceWrapper        (instance)
          <Cards>k__BackingField        -> Dictionary<int,int>   (collection)
          m_inventory                   -> ClientPlayerInventory
                                            { wcCommon, wcUncommon,
                                              wcRare,  wcMythic,
                                              gold, gems, vaultProgress }
```

**Field resolution rule** (from spike 5):
1. Exact name match first.
2. Fall back to `<UpperCamel>k__BackingField` (C# auto-property backing
   field) — with a single leading underscore stripped and first letter
   uppercased on the requested name.
3. Static vs instance: dispatch on `MONO_FIELD_ATTR_STATIC = 0x10` in
   `MonoClassField.type->attrs`. Static reads from
   `vtable->data[field->offset]`; instance reads from
   `obj_ptr + field->offset`.

## Canonical sources

Walker offsets must be confirmed against **at least two independent
sources** before any `#[repr(C)]` or offset constant is pinned in the
Rust crate. The ranked sources are:

1. **Unity-Technologies/mono @ `unity-2022.3-mbe`** (MIT).
   Authoritative struct definitions. Pull the raw file via
   `gh api -H 'Accept: application/vnd.github.raw' 'repos/Unity-Technologies/mono/contents/mono/metadata/<file>?ref=unity-2022.3-mbe'`.
   Key files:
   - `mono/metadata/class-private-definition.h` — `struct _MonoClass`
     (the real definition; `class-internals.h` only forward-declares it)
   - `mono/metadata/class-internals.h` — `struct _MonoClassField`,
     `struct MonoVTable`, `union _MonoClassSizes`, `enum MonoTypeKind`
   - `mono/metadata/class-getters.h` — the full `m_class_offsetof_*`
     macro list; authoritative field-name manifest
   - `mono/metadata/domain-internals.h` — `struct _MonoDomain`
   - `mono/metadata/metadata-internals.h` — `struct _MonoAssembly`,
     `_MonoAssemblyName`, `_MonoImage`
   - `mono/metadata/object-internals.h` — `_MonoArray`, `_MonoString`
2. **Live disassembly of MTGA's `mono-2.0-bdwgc.dll`** (see
   "Disassembly evidence" below). Authoritative for *this specific build*;
   deviates from source only if the build pinned a patch.
3. **Unispect / Unispect-DMA** — AGPL-3.0. Technique and cross-check only;
   **do not copy source**. Useful as a third independent voice when the
   first two disagree.

Conditional-compilation gates that change layout between builds:
`DISABLE_REMOTING`, `DISABLE_COM`, `MONO_SMALL_CONFIG`,
`ENABLE_CHECKED_BUILD_PRIVATE_TYPES`. The Unity MonoBleedingEdge build
has **none** of these defined — every `#ifndef DISABLE_*` branch is
taken. Verify this assumption against any new build before trusting
derived offsets.

## Verified findings (2026-04-25 reading of MTGA build timestamp
`Fri Apr 11 17:22:20 2025`, file size 7,897,520 bytes)

### Export RVAs in `mono-2.0-bdwgc.dll`

| Export | Ordinal | RVA | File offset |
|---|---:|---:|---:|
| `mono_get_root_domain` | 489 | `0x000a71b0` | `0x000a65b0` |
| `mono_assembly_loaded` | 69 | `0x000b6be0` | `0x000b5fe0` |
| `mono_domain_assembly_open` | 301 | `0x000a7e50` | `0x000a7250` |
| `mono_class_vtable` | 183 | `0x001ca860` | `0x001c9c60` |
| `mono_class_get_field_from_name` | 135 | `0x000bd140` | `0x000bc540` |
| `mono_image_loaded` | 526 | `0x0014cdb0` | `0x0014c1b0` |

These are derived from the PE export directory at RVA `0x73be00`.
To re-derive on a newer build, parse the export directory (or use
`native/scry2_collection_reader/src/walker/pe.rs::find_export_rva`).

### `mono_get_root_domain` prologue — validated

First 8 bytes at RVA `0xa71b0`:

```
48 8b 05 69 9e 6a 00  c3
mov  rax, [rip+0x6a9e69]
ret
```

Canonical `mov rax, [rip+disp32]; ret` pattern expected by
`walker/prologue.rs`. Derived static pointer address:

- RIP after mov = `0xa71b0 + 7 = 0xa71b7`
- disp32 = `0x006a9e69`
- `mono_root_domain` static pointer RVA = `0xa71b7 + 0x6a9e69 = 0x746020`

At runtime, `read_u64(mono_base + 0x746020)` yields the live
`MonoDomain *`.

### Disassembly evidence for struct offsets (first-pass, needs confirmation)

Leading bytes of `mono_class_vtable(MonoDomain *domain, MonoClass *class)`:

```
1801ca880  mov  rdi, rdx               ; rdi = class
1801ca888  mov  r14, rcx               ; r14 = domain
   ...safepoint / telemetry prologue...
1801ca954  test dword [rdi+0x28], 0x100000
1801ca95d  mov  rax, qword [rdi+0xe0]
```

- `[rdi+0x28]` read as a 32-bit flags word with `0x100000` likely being
  `MONO_CLASS_IS_ARRAY`-adjacent — suggests the bitfield byte cluster in
  `_MonoClass` around the `inited/valuetype/enumtype/...` group lives
  at offset `0x28`. **First-pass candidate**, not confirmed.
- `[rdi+0xe0]` looks like `MonoClass.runtime_info` (used to find a
  per-domain VTable). **First-pass candidate**, not confirmed.

Leading bytes of `mono_class_get_field_from_name(MonoClass *klass, const char *name)`:

```
1800bd14a  ...
1800bd164  mov  rdi, rcx               ; rdi = klass
1800bd20e  test dword [rdi+0x28], 0x100000
1800bd226  mov  rbx, qword [rdi+0x98]
```

- `[rdi+0x98]` is likely `MonoClass.fields` — the MonoClassField array
  the function iterates. **First-pass candidate**, not confirmed.

### Verified offset table (2026-04-25 reading)

Cross-checked by two independent sources: the `offsets_probe/dump.c`
program (compiled with `gcc -mms-bitfields` against Unity's headers)
and live disassembly of the MTGA DLL. Values marked ✓ agree between
both sources.

**`MonoClass`:**

| Offset | Field | Evidence |
|---:|---|---|
| 0x00 | `element_class` | dumper |
| 0x08 | `cast_class` | dumper |
| 0x10 | `supertypes` | dumper |
| 0x18 | `idepth` (u16) | dumper |
| 0x1a | `rank` (u8) | dumper |
| 0x1b | `class_kind` (u8) | dumper |
| 0x1c | `instance_size` (i32) | dumper |
| 0x20 | bitfield group 1 (`inited`…`is_byreflike`) | dumper |
| 0x24 | `min_align` (u8) | dumper |
| 0x28 | bitfield group 2 (`packing_size`…`has_dim_conflicts`, 23 bits; `has_failure` at bit 20) | ✓ dumper + `test [rdi+0x28], 0x100000` in `mono_class_vtable` |
| 0x30 | `parent` | dumper |
| 0x38 | `nested_in` | dumper |
| 0x40 | `image` | dumper |
| 0x48 | `name` | dumper |
| 0x50 | `name_space` | dumper |
| 0x58 | `type_token` (u32) | dumper |
| 0x5c | `vtable_size` (i32) | dumper |
| 0x60 | `interface_count` (u16) | dumper |
| 0x64 | `interface_id` (u32) | dumper |
| 0x68 | `max_interface_id` (u32) | dumper |
| 0x6c | `interface_offsets_count` (u16) | dumper |
| 0x70 | `interfaces_packed` | dumper |
| 0x78 | `interface_offsets_packed` | dumper |
| 0x80 | `interface_bitmap` | dumper |
| 0x88 | `interfaces` | dumper |
| 0x90 | `sizes` (union, 4 bytes) | dumper |
| 0x98 | `fields` | ✓ dumper + `mov rbx,[rdi+0x98]` in `mono_class_get_field_from_name` |
| 0xa0 | `methods` | dumper |
| 0xa8 | `this_arg` (MonoType, 16 bytes) | dumper |
| 0xb8 | `_byval_arg` (MonoType, 16 bytes) | dumper |
| 0xc8 | `gc_descr` (pointer-sized) | dumper |
| 0xd0 | `runtime_info` | ✓ dumper + `mov rsi,[rdi+0xd0]` in `mono_class_vtable` post-`has_failure`-branch |
| 0xd8 | `vtable` | dumper |
| 0xe0 | `infrequent_data` (`MonoPropertyBag`, 8 bytes) | ✓ dumper + `mov rax,[rdi+0xe0]` in `mono_class_vtable` on-`has_failure` branch |
| 0xe8 | `unity_user_data` | dumper |

Total `sizeof(MonoClass) = 240` (= 0xf0).

**`MonoClassField`** (each entry 32 bytes):

| Offset | Field |
|---:|---|
| 0x00 | `type` (`MonoType *`) |
| 0x08 | `name` (`const char *`) |
| 0x10 | `parent` (`MonoClass *`) |
| 0x18 | `offset` (i32) |

**`MonoVTable`** (base size 80, plus flex trailing `vtable[]`):

| Offset | Field |
|---:|---|
| 0x00 | `klass` |
| 0x08 | `gc_descr` |
| 0x10 | `domain` |
| 0x18 | `type` |
| 0x20 | `interface_bitmap` |
| 0x28 | `max_interface_id` (u32) |
| 0x2c | `rank` (u8) |
| 0x2d | `initialized` (u8) |
| 0x2e | `flags` (u8) |
| 0x34 | `imt_collisions_bitmap` (u32) |
| 0x38 | `runtime_generic_context` |
| 0x40 | `interp_vtable` |
| **0x48** | **`vtable[0]` — start of static storage / method trampolines** |

`vtable->data[offset]` reads (for STATIC-flagged fields) land at
`vtable_base + 0x48 + offset`. This is the address the walker uses to
read `PAPA.<Instance>k__BackingField`.

**`MonoObject`** (16 bytes):

| Offset | Field |
|---:|---|
| 0x00 | `vtable` |
| 0x08 | `synchronisation` |

**`MonoArray`** (32 bytes fixed + flex trailing `vector[]`):

| Offset | Field |
|---:|---|
| 0x00 | `obj` (MonoObject) |
| 0x10 | `bounds` |
| 0x18 | `max_length` (uintptr_t) |
| **0x20** | **`vector[0]` — start of element storage** |

**`MonoDomain`:**

| Offset | Field | Evidence |
|---:|---|---|
| 0x90 | `state` (u32) | `cmp DWORD PTR [rcx+0x90], 0x3` in `mono_domain_assembly_open_internal` (rcx = domain) |
| 0x94 | `domain_id` (i32) | `movsxd rcx,[r14+0x94]` in `mono_class_vtable` fast path (`r14` = domain param) |
| 0x98 | `shadow_serial` (i32) | source order — `gint32` immediately after `domain_id` per `domain-internals.h` |
| 0xa0 | `domain_assemblies` (GSList *) | ✓ source order (8-byte aligned after `shadow_serial`) + `mov r14,[r13+0xa0]; mov rsi,[r14]; mov r14,[r14+0x8]` GSList loop in `mono_domain_assembly_open_internal` (loop at `1800a8219..1800a828d`) |

Class-VTable hash and other `MonoDomain` fields are still TBD — those
land when the walker stops needing the assembly walk and switches to
`class_vtable_hash` for class lookup.

**`GSList`** (mono/eglib singly linked list, 16 bytes):

| Offset | Field |
|---:|---|
| 0x00 | `data` (gpointer) |
| 0x08 | `next` (`GSList *`) |

✓ dumper + live disassembly: `mov rsi,[r14]` (data) and
`mov r14,[r14+0x8]` (next) form the GSList loop in
`mono_domain_assembly_open_internal`.

**`MonoAssemblyName`** (80 bytes, ENABLE_NETCORE off in MBE so `major`/
`minor`/`build`/`revision`/`arch` are u16):

| Offset | Field |
|---:|---|
| 0x00 | `name` (`const char *`) |
| 0x08 | `culture` (`const char *`) |
| 0x10 | `hash_value` (`const char *`) |
| 0x18 | `public_key` (`const mono_byte *`) |
| 0x20 | `public_key_token[17]` |
| 0x34 | `hash_alg` (u32) |
| 0x38 | `hash_len` (u32) |
| 0x3c | `flags` (u32) |
| 0x40 | `major`/`minor`/`build`/`revision`/`arch` (5 × u16) |

**`MonoAssembly`** (truncated to `image` — fields beyond not consumed):

| Offset | Field | Evidence |
|---:|---|---|
| 0x00 | `ref_count` (i32) | dumper |
| 0x08 | `basedir` (char *) | dumper |
| 0x10 | `aname` (`MonoAssemblyName`, embedded) — first field is `aname.name` so `[asm+0x10]` IS the name pointer | ✓ dumper + `mov rax,[rbx+0x10]` reading the assembly name in `mono_domain_assembly_open_internal` (rbx = assembly) |
| 0x60 | `image` (`MonoImage *`) | ✓ dumper + `mov rsi,[rsi+0x60]` reading the image pointer right after dereferencing the GSList data slot |

**`MonoImage`** (truncated to `assembly_name`):

| Offset | Field |
|---:|---|
| 0x00 | `ref_count` (int) |
| 0x08 | `storage` (`MonoImageStorage *`) |
| 0x10 | `raw_data` (char *) |
| 0x18 | `raw_data_len` (u32) |
| 0x20 | `name` (char *) |
| 0x28 | `filename` (char *) |
| 0x30 | `assembly_name` (`const char *`) |

✓ dumper. Live-disassembly cross-check on these will land when the
walker reads `MonoImage.class_cache` (next phase of class lookup).

**`MonoClassRuntimeInfo`** (inferred from `mono_class_vtable` fast path):

| Offset | Field |
|---:|---|
| 0x00 | `max_domain` (u16) |
| 0x08 | `domain_vtables[N]` (array of pointers, indexed by `domain_id`) |

### The disagreement that is now resolved

Earlier sessions flagged a `0xd0 vs 0xe0` disagreement on
`runtime_info`. Root cause: the disassembly I initially eyeballed as
the runtime_info load was actually on the `has_failure` branch, where
`[rdi+0xe0]` reads `infrequent_data` (the property bag used to fetch
the failure's exception data). The real runtime_info load is at
`[rdi+0xd0]` on the non-failure branch. Both the dumper and the live
disassembly now agree: `runtime_info = 0xd0`. The earlier
interpretation error was mine, not a build-layout anomaly.

### Walker code in sync

`native/scry2_collection_reader/src/walker/mono.rs`'s
`MonoOffsets::mtga_default()` pins `class_fields=0x98`,
`class_runtime_info=0xd0`, `class_flags_cluster=0x28` — all verified.
The module's unit tests (43 across the crate) exercise every accessor
against synthetic byte buffers. No live-memory reads yet; those land
when `field.rs` / `dict.rs` / `inventory.rs` are wired up.

## Struct offsets — open work

The walker's `mono.rs` module pins offsets verified by both the
`offsets_probe/` dumper and live disassembly. Remaining offsets needed
for the next walker module (`class_lookup`):

- `MonoImage` — `class_cache` (`MonoInternalHashTable`)
- `MonoInternalHashTable` — bucket array head, table size, key/next
  field offsets within `MonoClass`-shaped chained nodes

### Method for each offset

For each field:
1. Locate the field in the Unity header (`class-private-definition.h`
   or equivalent).
2. Count bytes from the top of the struct, respecting:
   - Pointer alignment (8 bytes on x86-64)
   - Bitfield packing (Windows `MSVC` ABI differs from Itanium/SysV —
     the MonoBleedingEdge Windows DLL uses MSVC bitfield rules)
   - `#ifdef` branches taken (see "Conditional-compilation gates" above)
3. Pick a Mono function that reads or computes with the field.
4. Disassemble it against MTGA's live bytes (see "Disassembly evidence"
   pattern above) to confirm the literal offset matches.
5. If the two agree, pin in `mono.rs`. If they diverge, widen the
   investigation — do not ship a guess.

### Disassembly recipe

```bash
DLL=/home/shawn/.local/share/Steam/steamapps/common/MTGA/MonoBleedingEdge/EmbedRuntime/mono-2.0-bdwgc.dll
# find the export:
objdump -p "$DLL" | grep -E '^\s+\[.*<symbol_name>'
# parse the export table yourself, or use walker/pe.rs::find_export_rva.
# then disassemble (VA = 0x180000000 + RVA):
objdump -d --disassembler-options=intel --start-address=<VA> --stop-address=<VA+N> "$DLL"
```

## Sibling module: the POC

`mtga-duress/experiments/mtga-reader-poc/` — working structural-scan
implementation. 4,091 cards recovered on the research machine in ~1.4s.
Does not use any Mono offsets. Value: its address-discovery and
`process_vm_readv`-based read primitives are a reference for how the
production crate handles memory access, even though the walker uses a
completely different locator strategy.

## Related scry_2 artifacts

- `native/scry2_collection_reader/src/walker/prologue.rs` — parses
  `mov rax, [rip+disp32]; ret` (validated against `mono_get_root_domain`
  above).
- `native/scry2_collection_reader/src/walker/pe.rs` — finds a named
  export in a mapped PE32+ image (used before `prologue.rs` runs).
- `decisions/architecture/2026-04-22-034-memory-read-collection.md` —
  ADR for the overall reader, including the walker-in-Rust decision
  (Revision 2026-04-25). Decision document, not a protocol reference —
  details live here.
- `plans.md` — "Currently in progress — Walker phase 6 (Rust)" tracks
  module status.
- `mtga-duress/experiments/spikes/spike{5,6,7,10}/FINDING.md` — prior
  research.
