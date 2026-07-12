---
status: accepted
date: 2026-07-12
---
# Netdeck Variant Matrix

## Context and Problem Statement

UIDR-013 (netdeck variant deltas, accepted 2026-07-11) added per-row
delta lines to the Variants section so the user could see how each
cluster member differs from the viewed deck. Before implementation,
mockup review against real data changed the conclusion: what the user
actually valued was **seeing many variants at once** — dense, text-only,
comparable in a single scan. Per-row delta lines serialize the same
information vertically (~6,000px at the 59-member worst case), and two
image- or chart-led alternatives (on-card consensus overlays, per-card
distribution bars) were rejected as laborious or not immediately
legible.

The corpus reality that shapes the design: the biggest cluster has 59
members, but the union of contested nonland cards stays small (5–22 rows
across every cluster with ≥5 members). A card×variant matrix is
therefore tall-bounded and only wide-unbounded — and width is solvable
with a frozen pane and horizontal scroll.

## Decision Outcome

Chosen option: "delta matrix — contested cards × variants, anchored to
the viewed deck", because it is the only explored form that shows the
whole cluster in one scan, and it subsumes both questions at once: read
a row for "what does the field disagree on" and a column for "how far is
that variant from mine".

* **Section**: "Variant matrix · N lists" on `/netdecks/:id`, below the
  Variants list. The Variants list itself is unchanged from UIDR-010 —
  provenance and navigation only, one line per row.
* **Rows**: the union of nonland cards on which any cluster member
  differs from the viewed deck, sorted most-contested first (number of
  members differing on that card). Row label: rarity dot + card name.
* **Frozen reference pane**: card name plus a `you ×N` column (the
  viewed deck's copy count, primary-tinted) stay fixed while the field
  scrolls horizontally.
* **Columns**: every other cluster member, best finish first (placement,
  then swiss rank, unplaced last) — the columns visible without
  scrolling are the top finishers. Column head: pilot name (rotated) and
  finish; the head links to that variant's detail page. **Pilot names
  are always real DOM text** — browser find must land on them; CSS
  ellipsis truncation is acceptable (the full string stays searchable),
  tooltip-only or placement-only headers are not.
* **Cells**: copies relative to the viewed deck — `+N` / `−N` (U+2212)
  in desaturated success/error tinted text, blank for same-as-viewed.
  No fills, no heatmap (UIDR-008). The sparseness is the signal: a solid
  row means the viewed list is alone on that card; a dense column means
  a distant variant.
* **Footer rows**: `Manabase ±N` and `Sideboard ±N` magnitude summaries
  per column, and an emphasized `Total Δ` row answering "how far from
  mine" in one number. Individual land and sideboard swaps are never
  itemized (consistent with UIDR-013's noise analysis).
* **Anchoring**: deltas are always relative to the deck whose page is
  open and re-anchor on navigation; never the cluster representative
  (whose identity mutates with the collection — the UIDR-010 trap).
* **Identity**: diffs computed by card-name identity so printings never
  render as false swaps; cards unresolvable against the local card
  database are excluded, never shown as "Unknown".
* **Degenerate cases**: clusters of one show no matrix (the Variants
  list is already hidden below two members). A member with an identical
  75 renders an all-blank column with `Total Δ 0` — visible honestly,
  not suppressed. Two-member clusters yield a one-column matrix, which
  is fine.
* **Interaction**: column hover highlights the column (crosshair with
  the row hover); no interaction is required to read any value.

This supersedes **UIDR-013's delta lines before implementation** — a
matrix column is that variant's delta, so per-row delta lines would be
a second rendering of the same information. UIDR-013's analysis (spell
signal vs land/sideboard noise, name-identity diffing, viewed-deck
anchoring) carries forward and is embedded above. The "contested slots"
consensus view deferred by UIDR-013 is absorbed: contested-ness is the
matrix's row order, and consensus reads directly from row density.

### Consequences

* Good, because the whole cluster is comparable in one screen — the
  59-member worst case renders as 22 rows with a horizontal scroll,
  best finishers visible by default.
* Good, because row density communicates consensus without a dedicated
  feature ("everyone plays one more Gearhulk" is a solid `+1` row).
* Good, because the section is text-only and Ctrl-F-able — pilots,
  card names, and counts are all searchable page text.
* Bad, because reading a specific far-off variant requires horizontal
  scrolling, and small screens see fewer columns at once.
* Bad, because manabase and sideboard detail is reduced to magnitudes;
  full fidelity requires navigating to the variant.
