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

**Module plan inside `walker/`:**

| Module | Status | Purpose |
|---|---|---|
| `prologue.rs` | ✅ done (commit `7f71245e`) | Parse `48 8b 05 disp32 c3` accessor body → absolute static-pointer address |
| `pe.rs` | next | PE export table walk: find `mono_get_root_domain` by name in `mono-2.0-bdwgc.dll` mapped bytes, return RVA |
| `mono.rs` | blocked on offset sourcing | `#[repr(C)]` defs for `MonoDomain` / `MonoAssembly` / `MonoImage` / `MonoClass` / `MonoClassField` / `MonoVTable` / `MonoObject` / `MonoArray`; offset table for Unity-mono-2022.3.x |
| `field.rs` | not started | Linear-scan a class's fields by name, with `<UpperCamel>k__BackingField` fallback; static/instance dispatch |
| `dict.rs` | not started | Iterate `Dictionary<int,int>._entries`; same Entry struct the existing scanner already understands |
| `inventory.rs` | not started | Read `ClientPlayerInventory` plain fields (`wcCommon` etc.) |
| `build_hint.rs` | not started | Read MTGA's build GUID from `boot.config` (separate read; not on the PAPA chain) |
| top-level `walk_collection(pid)` | not started | Orchestrate the chain; return `WalkResult` |

**NIF wiring** (last step before Elixir integration): add
`walk_collection` as a fourth `#[rustler::nif(schedule = "DirtyIo")]`
in `lib.rs`, returning a tagged `{:ok, %{...}}` map matching the shape
specified in the ADR revision.

**Elixir integration plan** (after Rust returns a usable `WalkResult`):

1. `Scry2.Collection.Mem` behaviour grows a `walk_collection/1` callback.
2. `Scry2.Collection.Reader.run/1` calls walker first; on `{:error, _}`
   falls back to the existing `Scanner` and stamps
   `reader_confidence = "fallback_scan"`. Walker success stamps
   `"walker"`.
3. `SelfCheck` validates the returned map (plausible card counts,
   wildcard non-negative, build hint shape).
4. `Snapshot` schema fields `wildcards_*` / `gold` / `gems` /
   `vault_progress` / `mtga_build_hint` (already present, currently
   nil) get populated.
5. The reconciliation diagnostics page's `walker share %` KPI starts
   reflecting walker hits.

**Mono offset sourcing — open task before `mono.rs`:** spike 7 lists
canonical sources to cross-reference: Unispect / Unispect-DMA, the
`joaoescribano/mtga-reader` Python reference, and disassembly of
`mono_assembly_loaded` / `mono_domain_assembly_open` /
`mono_class_vtable` exported functions in the live MTGA process.
Confirm offsets from at least two independent sources before pinning
in `mono.rs`. Build-string detection logs an advisory warning on an
unknown Unity build, never a hard fail.

**Test posture:** every Rust module gets `#[cfg(test)] mod tests` with
inline byte-array fixtures; no live MTGA needed for unit tests. Live
integration test exists in Elixir under `@tag :external` and is
excluded from default `mix test`.

**Ship signal:** at any point the prior commit's tests must stay
green, `cargo clippy --all-targets` must not regress, and `mix compile`
must succeed. After `walk_collection` is wired, the user-visible
signal is `reader_confidence == "walker"` on a fresh refresh.

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
