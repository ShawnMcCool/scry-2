---
status: superseded by UIDR-014
date: 2026-07-11
---
# Netdeck Variant Deltas

> Superseded before implementation by
> [UIDR-014](2026-07-12-014-netdeck-variant-matrix.md): the variant
> matrix shows every member's delta at once, making per-row delta lines
> a redundant second rendering. The analysis below (spell signal vs
> land/sideboard noise, name-identity diffing, viewed-deck anchoring)
> carries forward into UIDR-014.

## Context and Problem Statement

The Variants section on `/netdecks/:id` (UIDR-010) lists every cluster
member with pilot, finish, record, date, and wildcard cost — but nothing
about *what is different in the 75*. Choosing between "the variant that
won" and "the variant I can afford" meant clicking through each one and
manually diffing two full decklists across page loads.

Real cluster data reshaped the design space. At the 0.7 Jaccard
threshold, no variant differs by one or two cards: measured diffs run
±18–32 main-deck cards plus ±8–14 sideboard cards. But the bulk of that
is manabase tuning — of one variant's ±18 main diff, 14 changes were
lands, and the spell delta was 4 named cards. Spell-only deltas across a
real 10-member cluster ran ±3–5 with a worst case of ±11. The signal is
the nonland delta; lands and sideboard are volume noise.

Three directions were mocked up against the real data: (1) always-visible
delta lines in each row, (2) one-line rows with a closeness gauge and an
expandable full-diff panel, (3) an inverted "contested slots" matrix
(rows = disputed cards, columns = variants).

## Decision Outcome

Chosen option: "always-visible inline delta lines, spells named, lands
and sideboard summarized", because it answers "what would I actually be
changing?" from the list itself, with zero added interaction, and it is
the only direction whose voice is indistinguishable from the existing
variants list.

* **Anchor**: every delta is relative to the deck whose detail page is
  open. Navigating to a variant re-anchors all deltas to it. Deltas are
  never computed against the cluster representative — that anchor
  silently mutates as the collection changes (the trap UIDR-010 exists
  to avoid).
* **Row shape**: each variant row becomes two lines. Line 1 is unchanged
  from UIDR-010 (pilot, finish, record, date, cost pips, viewing badge).
  Line 2 is the delta, always visible.
* **Spell deltas**: named, as `+N Name` / `−N Name` (U+2212 minus).
  Additions first (they are what the user would craft), then cuts,
  alphabetical within each. At most 6 named entries, then a low-opacity
  italic `+N more…`. The line wraps; it never clips.
* **Color**: tint lives on the sign glyph only — desaturated
  success/error at roughly half theme chroma (UIDR-008: no solid fills,
  no chips). Colorblind backup channel: addition names render slightly
  brighter than cut names.
* **Lands and sideboard**: collapsed to `lands ±N · sideboard ±N`, one
  register quieter than the spell tokens. Zero-change groups are omitted.
  Individual land swaps are never named — they would bury the 3–5 spell
  changes that matter under 10–16 manabase edits.
* **Identity**: deltas are computed by card-name identity (as
  `OwnedIdentity` matches ownership), so two printings of the same card
  never render as a false `+/−` pair. Cards unresolvable against the
  local card database are excluded from named deltas — never rendered as
  "Unknown" — consistent with how scoring already treats them.
* **Degenerate cases**: a variant differing only in lands shows just
  `lands ±N`; only in sideboard, just `sideboard ±N`; an identical 75
  shows a "same 75" note instead of an empty line. The viewing row shows
  no delta — an italic "the list you're viewing" marks the anchor.

Deferred, recorded here as future work: a **contested-slots matrix** —
rows are the cards the cluster disagrees on sorted by contestedness,
columns are variants, cells are counts relative to the viewed list. The
mockup surfaced real cluster-level insight (consensus cards the viewed
list lacks; two pilots registering card-for-card identical 75s) but it
is an archetype-consensus feature, not a variants-list enhancement. The
expandable full-diff direction was dropped outright: navigating to the
variant already provides full fidelity.

### Consequences

* Good, because variant comprehension becomes passive — the delta is
  read in the same scan as finish and cost, with no interaction.
* Good, because cross-row repetition of the same delta token (e.g.
  `+1 Get Lost` on 9 of 9 variants) honestly reveals cluster consensus
  the viewed list is missing.
* Good, because sort order, provenance fields, cost pips, and navigation
  from UIDR-010 are untouched.
* Bad, because the section roughly doubles in height (measured ~460px →
  ~1050px for a 10-variant cluster).
* Bad, because manabase and sideboard detail is not available anywhere
  on the page — the summaries name a magnitude only, and full fidelity
  requires navigating to the variant.
