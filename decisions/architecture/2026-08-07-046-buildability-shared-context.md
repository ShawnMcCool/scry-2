---
status: accepted
date: 2026-08-07
---
# 046. Buildability is a shared context, not a NetDecking feature

## Status

Accepted

## Context and Problem Statement

Scoring a card list against the player's collection — how many copies of which
cards are missing, and what the rest would cost in wildcards — shipped inside
`Scry2.NetDecking` (ADR-040). None of it is netdeck-specific: the engine takes a
maindeck, a sideboard, and a collection, and returns per-section wildcard cost,
shortfall, owned percentage, and a status.

The player's own decks want the same answer. MTGA lets you save a deck
containing cards you don't own and shows the craft cost; `/decks/:id` showed
nothing. Wiring it up naively meant one of two bad outcomes:

- `Scry2Web.DecksLive` calls `Scry2.NetDecking` — your own deck scored by a
  module named NetDecking, and every future deck surface pulled toward the
  netdeck context.
- The scoring is duplicated in `Scry2.Decks` — two implementations of one idea,
  free to drift.

The web side had the same problem. `Scry2Web.DeckRendering.standard_composition/1`
already exposed the hooks (`card_class`, `count_entry`, `card_overlay`), but the
functions that *fill* them — the ownership wash, the toned gutter count, the
missing-card tint, the ownership tooltip — lived in `Scry2Web.NetdecksHelpers`
and as private components in `Scry2Web.NetdecksLive`. Each new page would have
re-written the eight lines of wiring.

A third problem surfaced while mapping this: nothing anywhere distinguished
"the player owns none of this" from "we have no collection snapshot". With no
snapshot, `owned` is `%{}` and every card scores as missing. On the netdeck
catalog that is merely useless; on the player's own deck page it would state,
as fact, that they own none of a deck they demonstrably built.

## Decision Drivers

* One representation per idea — deck ownership is one concept, not one per page.
* Domain naming: a module scoring the player's own deck must not be named for
  external decks.
* No context inversion: `Scry2.Collection` is a source context; making it depend
  on `Cards` and `Economy` to host scoring inverts the layering.
* Never present unknown data as fact (see the "no fabricated UI narrative"
  standard).

## Considered Options

1. **`Scry2.Buildability` as a new tables-less context** consuming `Cards`,
   `Collection` and `Economy`; NetDecking and Decks both consume it.
2. **Move scoring into `Scry2.Collection`** — the context that owns ownership.
3. **Leave the engine in NetDecking**, extract only the web ownership layer.
4. **Bolt on** — DecksLive calls NetDecking and copies the wiring.

## Decision Outcome

Chosen: **option 1**.

`Scry2.Buildability` owns no tables — a read model, like `Players` and
`Console` before it. Its pipeline is three stages:

1. `CollectionPosition.current/1` reads the collection once: owned copies rolled
   up across printings (`OwnedIdentity`), wildcard balances (snapshot, falling
   back to the log-derived `Economy` inventory), rarities, and the free
   (basic land) arena_ids.
2. `ScoreCardList` applies the pure rules — per-card shortage → rarity buckets →
   affordability → status and sort key — plus the per-card `CardRow`s.
3. `assess/4` bundles both into an `Assessment`, the value the UI renders.

Callers scoring many lists take the position once and call `score/4` per list, so
the netdeck catalog still pays for exactly one collection read per page.

On the web side, `Scry2Web.DeckRendering.Ownership` is the ownership layer of the
rendering engine, alongside `ViewSpec` and `CompositionPrefs`.
`standard_composition/1` takes an `ownership` assessment and wires all three
hooks itself, so a page passes the assessment and nothing else — every deck
surface annotates identically by construction. `Scry2Web.WildcardCost` holds the
aggregate side: cost pips, the compact `"2u 1r"` label, and the common→mythic
ordering.

`collection_known?` rides on both the position and the assessment.
`Ownership.rows_index/1` returns `%{}` when it is false, so no annotation renders
at all, and the pages show a note pointing at the collection reader instead.
`NetDecking.archetype_detail/1` gates its craft pips the same way.

Option 2 was rejected because it points `Collection` at `Cards` and `Economy`,
inverting the layering for a purely derived read model. Option 3 leaves the
wrong owner in place — the coherence problem, unfixed, one layer down. Option 4
is the bolt-on this decision exists to prevent.

### Consequences

* Good: one scoring path for the netdeck catalog, netdeck detail, archetype
  cores, and the player's own decks. A new deck surface is one attr.
* Good: `NetDecking` shed its private `card_rows/5`, `collection_context/1`,
  `snapshot_wildcards/1`, `economy_wildcards/0` and `owned_by_identity/2`, and
  its five threaded scoring arguments collapsed to one `CollectionPosition`.
* Good: the unknown-collection case is now modelled rather than silently
  mis-rendered.
* Neutral: `NetDecking.deck_detail/1` returns `assessment:` instead of flat
  `result`/`wildcards`/`main_rows`/`side_rows` keys, and
  `archetype_detail/1` returns `core_assessment:` instead of
  `core_rows_by_arena_id:`.
* Bad: `Scry2.Buildability` is a context that owns no tables, which reads
  unusual next to the projection contexts. `Players` and `Console` set the
  precedent; the alternative was worse.

## More Information

* Engine and value types: `lib/scry_2/buildability/`.
* Rendering layer: `lib/scry_2_web/components/deck_rendering/ownership.ex`,
  `lib/scry_2_web/components/wildcard_cost.ex`.
* Ownership across printings: [ADR-040](2026-06-29-040-netdecking-automated-sourcing.md).
* Count placement rules the overlay obeys:
  [UIDR-015](../user-interface/2026-07-12-015-deck-view-count-placement.md).
* The rendering engine itself:
  [UIDR-012](../user-interface/2026-07-11-012-deck-rendering-engine.md).
