# offsets_probe

One-shot C dumper for Mono struct offsets under the Unity MonoBleedingEdge
`unity-2022.3-mbe` configuration that MTGA ships.

Struct bodies are verbatim from the Unity mono headers. Supporting
typedefs are reproduced minimally with `_Static_assert`s guarding every
width that affects layout.

Compiles with native GCC on Linux using `-mms-bitfields` so bitfields
follow MSVC's packing rules (the bitfield-group accumulation behaviour
that matches what MTGA's MSVC-built DLL uses at runtime).

## Run

```sh
gcc -mms-bitfields -Wall -o dump dump.c && ./dump
```

## Purpose

The Rust walker (`src/walker/mono.rs`) depends on exact struct offsets
for `MonoClass`, `MonoClassField`, `MonoVTable`, `MonoObject`, and
`MonoArray`. Offsets are pinned in `MonoOffsets::mtga_default()`.
Re-run this dumper when:

- The walker adds a new field to `MonoOffsets`.
- MTGA ships on a different Unity / mono version.
- A walker test fails with `:unmapped` or obviously-wrong pointer values
  after an MTGA update.

Cross-reference the printed offsets against live disassembly of
`mono-2.0-bdwgc.dll` per the recipe in the project's
`mono-memory-reader` skill before updating `mono.rs`.

## Not in the build

This file is **not** compiled by `cargo build`. It sits here alongside
the Rust crate so the maintenance workflow is colocated with the code
that consumes its output.
