---
status: accepted
date: 2026-07-16
---
# Netdecks Index — Tiered Archetype Catalog, Editorial Direction

## Context and Problem Statement

The netdecks index groups Jaccard-cluster representatives into three flat
buildability sections (UIDR: "Buildable now / Craftable now / Within
reach"). Since ADR-043, every corpus deck carries a classified archetype
(`archetype_name`, `archetype_variant`, `archetype_fallback`), which the
flat listing ignores — twelve Izzet Prowess lists scatter across all
three sections as unrelated tiles.

The catalog should answer "which archetypes can I play, and how cheaply"
— archetype first, list second. How should the index group, order,
present, and navigate an archetype-centric catalog?

## Decision Outcome

Chosen after a three-direction mockup review (exhibit gallery,
command board, editorial provenance): **a tiered archetype catalog in
the editorial/tournament-report direction** — mockup preserved at
`docs/superpowers/netdecks-archetype-catalog/`.

### Structure

* **Tier membership is the best member's status.** Tier I "Buildable
  now" — archetypes with ≥1 fully-owned variant. Tier II "Craftable
  now" — not in I, ≥1 variant within current wildcards. Tier III
  "Within reach" — the rest. An archetype appears in exactly one tier.
* **One grouping per `archetype_name`.** `archetype_variant` is a
  per-deck annotation inside the group, never a grouping key.
  Fallback-classified decks (`archetype_fallback: true`) group under
  their fallback label like any other archetype.
* **Read-time Jaccard clustering runs corpus-wide, before grouping;
  clusters are labeled by their members' majority `archetype_name`.**
  A variant row is a cluster representative with a ×N count; the variant
  matrix on the deck detail is unchanged (UIDR-014). Clustering first is
  what lets an archetype adopt near-duplicates the classifier missed — a
  list one card-swap away from Izzet Spellementals joins that group
  instead of spawning a synthetic "Izzet · Namor the Sub-Mariner"
  archetype. Only clusters with no classified member fall back to a
  synthetic color · hero label.
* **Variants live on a dedicated archetype detail route** — masthead
  (name, mana pips, status tally, best finish) above a variant table
  grouped buildable → craftable → short. No inline expansion or drawer.
* **The archetype detail leads with the core** — the archetype's typical
  list (every card in at least half the member lists, at its modal copy
  count) rendered as type-grouped image stacks with the player's
  ownership overlaid (dim wash + toned counts), so the summary doubles
  as a craft checklist. Each variant row then shows only its differences
  from that core: art chips grouped by broad type, labeled +N/−N with
  additions and cuts toned apart. All derived from list composition —
  no fabricated stats.
* **Ownership counts never cover the card** — the netdeck deck views
  route ownership-toned counts through the UIDR-015 gutter rail
  (bottom-left splay badge elsewhere). The engine's `card_overlay` slot
  is additive-only annotation (the dim wash); consumers that draw their
  own counts declare `count_placement: :none`.
* **Synthetic groups are labeled** — nil-archetype rows and mastheads
  carry a ghost "unclassified" badge distinguishing them from
  community-named archetypes.

### Ordering — stated on the page

* Tier I orders by **best competitive finish** (cheapest-first is
  degenerate at zero cost); Tiers II/III order **cheapest build first**
  (existing `Buildability.sort_key`, applied to the group's cheapest
  variant). Each tier's subtitle names its rule ("ordered by best
  finish" / "ordered by cheapest build") so the rank numerals are
  self-explaining.

### Presentation

* **Ranked single-column rows per tier**, not a card grid: ghost serif
  rank numerals, hairline rules instead of filled cards, serif
  archetype names, finish medallions (gold 1st / silver podium /
  squarish league "5–0") as the headline element, status-tinted variant
  tally, cheapest cost as rarity pips + compact label. Soft/ghost
  states only (UIDR-008).
* **Wildcard balance readout** in the source strip: small-caps label +
  four rarity-pipped figures (the player's pool), plain ink — no
  scarcity tinting. It is the context that makes every cost below
  interpretable.
* **Costs render as count + rarity icon** (the app's existing encoding,
  e.g. "2 ⟐r 1 ⟐m"), not the mockup's dot-per-wildcard pips — so the
  mockup's 8-pip cap has nothing to mitigate and was dropped. The count
  always carries the exact number.

### Archetype art identity — "the card this archetype plays that others don't"

The tile's signature art comes from the group's most **distinctive**
core card, TF-IDF style over the corpus (all decks are
archetype-stamped): rank nonland cards by average copies per list
within the group, discounted by how many other archetype groups play
the card; rarity and arena_id are deterministic tiebreakers only.
Ubiquity alone crowns a common cantrip; rarity alone crowns a format
staple (removal, counterspells, bounce) or a flashy 1-of mythic — the
distinctiveness quotient is what selects e.g. Stormchaser's Talent over
Into the Flood Maw for Izzet Prowess. Pure function in `DeckQualities`;
explicitly a replaceable heuristic — noisy on a thin corpus, where its
failure mode is the second-most-distinctive card, not a staple.

### Consequences

* Good, because the catalog reads as a metagame ("which decks"), with
  economics subordinate — matching how players think about netdecking.
* Good, because tier membership, ordering, and art identity are all
  pure derivations from existing data (`Buildability`, provenance,
  archetype stamps) — no new tables, no stored projection.
* Good, because the archetype detail route gives archetypes a stable,
  linkable identity the old cluster tiles never had.
* Neutral, because the single-column list trades density for
  hierarchy; past ~30 archetypes the search filter must do real work.
* Bad, because archetype grouping depends on classification quality —
  a misclassified deck drags its whole group's tier; mitigated by
  `Workers.ReclassifyArchetypes` re-stamping on definition updates
  (ADR-043).
