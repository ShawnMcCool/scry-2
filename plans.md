# scry_2 — capability roadmap from MTGA memory reading

A living tracker of capabilities unlocked by reading MTGA's process memory,
beyond what `Scry2.Collection` already does (cards dictionary snapshot via
the structural scanner). Each item is tagged with its prerequisite:

- **today** — buildable now with the existing scanner output
- **walker** — gated on walker phase 6 (wildcards, gold, gems, vault, build hint)
- **live** — gated on a new continuous-poll subsystem (no GenServer yet)
- **reader+** — gated on extending the memory reader to a new structure

This is a brainstorm tracker, not a commitment. Order is not priority.

## Currently in progress — Walker phase 6 (Rust)

**Why this is the focus:** Section B is FOCUS, and Walker phase 6 is the
single piece of structural work that unlocks ~10 downstream items across
B (currency / booster / log-gap reconciliation), E (forecasting), and
most of F (alerts). Cards reading already works via structural scan; the
walker replaces that with named-pointer navigation through Mono and
picks up wildcards / gold / gems / vault / build-hint on the same trip.

**Decision (ADR-034 Revision 2026-04-25):** walker is **in Rust**, not
Elixir. The original ADR put it in Elixir to keep "one language for
logic"; on closer look, hand-rolled Mono C-struct decoding in Elixir
bitstring syntax is too error-prone vs. Rust's `#[repr(C)]` casts.
Performance was not the driver — the walker reads <1 MB total. Elixir
keeps orchestration, self-check, fallback-to-scanner, snapshot
persistence, and UI. Scanner stays in Elixir.

**Pointer chain to navigate** (verified end-to-end via the spike 7 POC,
just via structural scan instead of a walker — the chain is correct,
the implementation route is what changes):

```
mono_get_root_domain()                  -> MonoDomain *
  PAPA  (search Core.dll then Assembly-CSharp.dll)
    <Instance>k__BackingField           [STATIC field, on PAPA's VTable]
      <InventoryManager>k__BackingField [instance]
        _inventoryServiceWrapper        [instance]
          <Cards>k__BackingField        -> Dictionary<int,int>  (collection)
          m_inventory                   -> ClientPlayerInventory
                                          { wcCommon, wcUncommon,
                                            wcRare,  wcMythic,
                                            gold, gems, vaultProgress }
```

**Field-resolution rule** (from spike 5): exact name first, then fall
back to `<UpperCamel>k__BackingField`. Static-vs-instance dispatch on
the `MONO_FIELD_ATTR_STATIC = 0x10` flag — static fields read from
`vtable->data[offset]`, instance fields from `obj_ptr + offset`.

**Design references** (read these before any new code):

- `decisions/architecture/2026-04-22-034-memory-read-collection.md` —
  the ADR; **Revision 2026-04-25** at the bottom contains the
  walker-in-Rust rationale and the revised NIF contract.
- `mtga-duress/research/002-mtga-memory-reader-design.md` — full
  evidence summary across all spikes.
- `mtga-duress/experiments/spikes/spike5_mono_metadata/FINDING.md` —
  field-resolution algorithm + which assemblies hold which classes.
- `mtga-duress/experiments/spikes/spike7_papa_walk/FINDING.md` —
  pointer chain + the list of Mono struct offsets the walker needs.
- `mtga-duress/experiments/spikes/spike6_runtime_root/FINDING.md` —
  prologue-byte pattern for `mono_get_root_domain`.

**Rust crate location:** `native/scry2_collection_reader/`. Existing
NIF surface (lib.rs): `ping`, `read_bytes`, `list_maps_nif`,
`list_processes_nif`. Walker work is gated on `mod walker` (with
`#![allow(dead_code)]` until `walk_collection` is wired).

**Walker session resume point (2026-04-25):**

124 unit tests passing in `native/scry2_collection_reader/`,
`cargo fmt --check` clean, `cargo clippy --all-targets` clean on all
walker code (only pre-existing `type_complexity` warnings remain in
`lib.rs` / `linux.rs` — unrelated). All struct offsets in
`MonoOffsets::mtga_default()` are cross-verified by `offsets_probe/`
and live disassembly; see `.claude/skills/mono-memory-reader/SKILL.md`
for evidence.

### Done

| Module | What it does |
|---|---|
| `prologue.rs` | Parse `48 8b 05 disp32 c3` accessor body → absolute static-pointer address. |
| `pe.rs` | PE32+ export-directory walk: find a named symbol's RVA in mapped DLL bytes. |
| `mono.rs` | 16-field `MonoOffsets` table (`MonoClass`, `MonoClassField`, `MonoType.attrs`, `MonoArray`, `MonoDomain.domain_id`, `MonoClassRuntimeInfo`, `MonoVTable.method_slots`) plus `MONO_CLASS_FIELD_SIZE`, `DICT_INT_INT_ENTRY_SIZE`, `MONO_FIELD_ATTR_STATIC` constants. Bounds-checked `read_u{8,16,32,64}` / `read_ptr` primitives and per-field typed accessors. |
| `field.rs` | `find_by_name` — two-pass resolution (exact → `<UpperCamel>k__BackingField`) over a class's `MonoClassField[]`. Generic over `Fn(u64, usize) -> Option<Vec<u8>>`. Returns `ResolvedField { type_ptr, parent_ptr, offset, is_static, name_found }`. |
| `dict.rs` | `read_int_int_entries` — `MonoArray<Entry>` walk filtering used slots via `hashCode == key & 0x7FFFFFFF`. 100K-entry sanity cap. |
| `inventory.rs` | `read_inventory` — resolves the seven literal `ClientPlayerInventory` fields (wcCommon/wcUncommon/wcRare/wcMythic/gold/gems/vaultProgress). All-or-nothing on any missing / static / negative-offset field. |
| `vtable.rs` | `class_vtable(class_addr, domain_addr)` resolves `MonoClass.runtime_info → max_domain bounds-check → domain_vtables[domain_id]`. `static_storage_base(...)` extends to `*(vtable + 0x48 + vtable_size*8)` — i.e. mono's `mono_vtable_get_static_field_data`. |
| `chain.rs` (innermost) | `from_service_wrapper` composes `field::find_by_name` + `dict::read_int_int_entries` + `inventory::read_inventory` into one `WalkResult { entries, inventory }`. End-to-end tested with a full FakeMem fixture covering three classes + three objects + the dictionary array. |
| `image_lookup.rs` | `find_by_assembly_name` walks `MonoDomain.domain_assemblies` (a `GSList` of `MonoAssembly *`) and returns the `MonoImage *` for the first assembly whose `aname.name` matches a target short name (e.g. `"Core"`, `"Assembly-CSharp"`). Bounded at `MAX_ASSEMBLIES = 1024` nodes so cycles can't hang the NIF. |
| `offsets_probe/dump.c` | Standalone C dumper compiled with `gcc -mms-bitfields` against Unity mono `unity-2022.3-mbe` headers. Used to verify every `MonoOffsets::mtga_default()` value. Now also covers `GSList`, `MonoAssemblyName`, `MonoAssembly` (truncated to `image`), and `MonoImage` (truncated to `assembly_name`). |

### Remaining — discrete next units

**Walker (Rust crate) modules in dependency order:**

| # | Module | Scope | Notes |
|---|---|---|---|
| 1 | `class_lookup.rs` | Walk `MonoImage.class_cache` (a `MonoInternalHashTable`) by name to find a `MonoClass *`. Used for `"PAPA"`, `"InventoryServiceWrapper"`, `"ClientPlayerInventory"`, `"InventoryManager"`, `"Dictionary`2"`. | New struct: `MonoInternalHashTable` — fetch its definition from `mono-internal-hash.h` (or wherever the unity-mbe variant lives), add offsets via the dumper, walk the chained-bucket layout. The class name to compare lives at `MonoClass.name = 0x48` (already in `MonoOffsets`). |
| 2 | `domain.rs` | Composite: parse `mono_get_root_domain` prologue → dereference static pointer → return live `MonoDomain *`. Combines `pe.rs` + `prologue.rs` + a single `read_u64` against the target process. | All sub-pieces exist — this is just orchestration. Input is the `mono-2.0-bdwgc.dll` mapped bytes plus the module's remote base address. |
| 3 | Outer `chain.rs` layers | `from_papa_class(class_addr, domain_addr, …class_bytes…)` — uses `vtable::static_storage_base` + `field::find_by_name("_instance")` to get the PAPA singleton, then walks `<InventoryManager>k__BackingField` (instance) → `_inventoryServiceWrapper` (instance) → delegates to existing `from_service_wrapper`. | Pure orchestration on top of `vtable.rs` + `field.rs`. Adds 2 new top-level helpers: `read_static_pointer` and `from_papa_class`. |
| 4 | Top-level `walk_collection(pid)` in `chain.rs` (or new `walker::run`) | Stitches everything: `list_maps` → find `mono-2.0-bdwgc.dll` base + bytes → `pe::find_export_rva` for `mono_get_root_domain` → `prologue::parse_mov_rax_rip_ret` → `read_u64` for live `MonoDomain *` → `image_lookup` for Core/Assembly-CSharp → `class_lookup` for the five classes → `from_papa_class` → `WalkResult`. | Returns `Result<WalkResult, WalkError>`. The error enum should distinguish the failure mode (no MTGA, can't find symbol, can't find class, dict cap exceeded, etc.) so the Elixir `Scry2.Collection.Reader` can route loudly. |
| 5 | `build_hint.rs` | Read MTGA's build GUID from `<MTGA root>/MTGA_Data/boot.config` — a plain key=value file on disk, **not** on the PAPA chain. Adds `mtga_build_hint` to `WalkResult`. | Trivial once the disk-path discovery (parse `/proc/<pid>/maps` for the MTGA install dir) is solved. |

**NIF wiring (last Rust-side step before Elixir):**

Add `walk_collection` as a fourth `#[rustler::nif(schedule = "DirtyIo")]`
in `native/scry2_collection_reader/src/lib.rs`. Map `WalkResult` →
`{:ok, %{wildcards_common: …, gold: …, cards: [%{arena_id, count}, …], mtga_build_hint: …}}`
matching the shape specified in ADR-034 Revision 2026-04-25.

**Elixir integration plan** (after the NIF returns a usable WalkResult):

1. `Scry2.Collection.Mem` behaviour grows a `walk_collection/1` callback.
2. `Scry2.Collection.Reader.run/1` calls walker first; on `{:error, _}`
   falls back to the existing `Scanner` and stamps
   `reader_confidence = "fallback_scan"`. Walker success stamps
   `"walker"`.
3. `SelfCheck` validates the returned map (plausible card counts,
   wildcards non-negative, build-hint shape).
4. `Snapshot` schema fields `wildcards_*` / `gold` / `gems` /
   `vault_progress` / `mtga_build_hint` (already present, currently
   `nil`) get populated.
5. The reconciliation diagnostics page's `walker share %` KPI starts
   reflecting walker hits.

**Test posture:** every Rust module gets `#[cfg(test)] mod tests` with
inline byte-array fixtures; no live MTGA needed for unit tests. Live
integration test will exist in Elixir under `@tag :external` and be
excluded from default `mix test`.

**Ship signal:** at any commit, prior tests stay green, `cargo
clippy --all-targets` does not regress, and `mix compile` must succeed.
After `walk_collection` is wired end-to-end, the user-visible signal
is `reader_confidence == "walker"` on a fresh refresh.

**Skill index:** `.claude/skills/mono-memory-reader/SKILL.md` is the
canonical reference for all walker offsets, the verification recipe
(via `offsets_probe/`), and live-disassembly evidence. Spike 10
retired `joaoescribano/mtga-reader` as a reference (it's not a memory
reader). Two independent sources per offset: (1) Unity mono
`unity-2022.3-mbe` headers + the dumper, (2) live disassembly of
MTGA's `mono-2.0-bdwgc.dll`. The skill carries per-offset evidence
citations.

## A. Snapshot extensions (one-shot reads, same model as today)

- Account identity (username, player UUID, account-creation timestamp) — **reader+**
- Constructed / Limited / Historic rank + tier + percentile — **reader+**
- Mastery pass tier, XP, free-vs-premium, mastery orbs — **reader+**
- Daily / weekly quest contents and progress — **reader+**
- Win-track (15-win) progress and claimed rewards — **reader+**
- Cosmetics inventory (pets, sleeves, avatars, alt arts, emotes) — **reader+**
- Event entry tokens (sealed, draft, premier-play) — **reader+**
- Active event records (e.g. 4-1 in a Premier Draft) — **reader+**
- Store inventory (daily deal, rotating bundles, cosmetic packs) — **reader+**
- Pending packs by set and source — **reader+**
- Build / version metadata (build GUID, asset version, server region) — **walker**

## B. Reconciliation (memory-vs-log truth diffing)  ← FOCUS

- Currency reconciliation (memory wildcards/gold/gems vs log `InventoryUpdated`) — **walker**
- Booster-count reconciliation (memory pack inventory vs log pack events) — **walker** + **reader+**
- Log-gap detector (currency change observed in memory but no matching log event) — **walker**
- Deck-list reconciliation (memory deck vs log-submitted deck) — **reader+**
- "Verify everything" admin button (runs every reconciliation) — composes above

## C. Pre/post-match capture (one-shot reads at known transitions)

- Pre-match deck snapshot when log fires `MatchCreated` — **reader+**
- Pre-match opponent snapshot from lobby memory — **reader+**
- Post-match economy delta (memory snapshot before/after match) — **walker**
- Pack-open card capture (memory snapshot before/after pack open) — **today**
- Companion legality verification — **reader+**

## D. Live tracking (continuous reads — new architectural mode)

Requires a `Scry2.LiveState` GenServer polling at ~4 Hz during active match
or draft. New PubSub topic. New isolation gate (settings flag, like the
reader-enabled flag).

- Active match HUD feed (life, hand, library, gy, exile, mana, stack) — **live** + **reader+**
- Real-time draft pack reader (cards seen but passed) — **live** + **reader+**
- Real-time mana / card-advantage tracker — **live** + **reader+**
- Opponent disconnect / concede early-detection — **live** + **reader+**
- Active-screen detection (lobby / deckbuilder / match / store) — **live** + **reader+**

## E. Forecasting (snapshot-stream analytics)

All gated on walker phase 6 producing a stream of currency/progression rows.

- Vault opening ETA from vault-progress slope — **walker**
- Mastery pass completion ETA vs season end — **walker**
- Currency burn-rate dashboard (gold/gems/wildcards over time) — **walker**
- Quest-reroll EV calculator — **walker** + **reader+**
- Win-track velocity / weekly reward attainment — **walker** + **reader+**

## F. Alerting / pre-action guardrails

- Wildcard floor alarm before a craft drops below threshold — **walker**
- Rank-decay countdown around month rollover — **reader+**
- MTGA build-change alert (revalidate parser/walker) — **walker**
- Cosmetic-on-sale-you-don't-own alert — **reader+**
- Quest-about-to-expire alert — **reader+**

## G. Brewing / deck library

- Deck library mirror (every saved deck in MTGA) — **reader+**
- Deck history / auto-backup on every change — **reader+** + **live**
- Sideboard awareness per deck — **reader+**
- Brew-in-progress capture for real-time companion UI — **reader+** + **live**

## H. Composed capabilities

- Personal draft database (every pack seen, every card passed) — **D + storage**
- Account-wide value tracker (collection value over time) — **walker** + **today**
- Real-time match exporter (OBS overlay, Discord bot, Twitch ext.) — **D**

## Cross-cutting prerequisites

- **Walker phase 6** — unlocks wildcards, gold, gems, vault progress, build
  hint. Active work: see "Currently in progress — Walker phase 6 (Rust)" at
  the top of this file. Specced in ADR-034 (Revision 2026-04-25) and
  `mtga-duress/research/002-*` + `mtga-duress/experiments/spikes/spike{5,6,7}/`.
  Most B/E/F items wait on this.
- **Live-state GenServer** — does not exist. Currently snapshots are one-shot.
  Adding a poll loop is a deliberate architectural step (settings flag, kill
  switch, isolation gate) — not a casual addition.
- **Reader extensions** (`reader+`) — each new memory structure (rank object,
  deck list, quest list, etc.) needs its own walker-style traversal. Current
  scanner only finds the cards dictionary. Each extension is its own ADR.
