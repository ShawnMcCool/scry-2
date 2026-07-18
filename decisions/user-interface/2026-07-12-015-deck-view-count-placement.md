---
status: accepted
date: 2026-07-12
---
# Deck View Count Placement — Gutter Rail

## Context and Problem Statement

UIDR-012 (deck rendering engine) parameterized how a card list renders:
`ViewSpec.piling: :piled` merges duplicate cards behind a count badge,
`:spread` renders every copy individually. But the badge's *position* is
not a parameter — it is hardcoded per layout inside the engine: top-right
of the card image for `:columns` (the deck page's splayed mana-value
stacks) and `:wrap` (draft pool), bottom-left for `:row` (sideboard
splay).

Top-right is where a Magic card prints its mana cost. In a vertically
splayed stack only the title strip of each card is visible, so the badge
covers the single most informative element of that strip. The user
noticed this immediately on the deck page: every stacked card's mana
cost was hidden behind its own count.

Overlay repositioning was explored and rejected: below the title bar
hides art; the left edge of the title bar hides the start of the name;
a fixed gap left of the mana cost collides with long names and 3+ symbol
costs. Card images are raster — there is no measurable "end of the name"
to anchor to. Any overlay position covers *something* printed.

## Decision Outcome

Chosen option: "reserve space beside the image — count placement becomes
a `ViewSpec` parameter", because the only position guaranteed to cover
nothing is off the card entirely, and per UIDR-012 every rendering
choice belongs in the spec, not in per-page markup.

* **`count_placement: :gutter`** — a narrow rail is reserved to the
  right of the card image; the count renders there as a plain dimmed
  number vertically aligned with its card's title strip. In a splayed
  stack the numbers form a clean vertical rail that reads like a text
  decklist's count column. This is the new default for the deck-page
  `:columns` stacks in `standard_composition`.
* **Blank means one.** The rail shows nothing for single copies — it
  carries only information, matching how a splay itself is read.
* **Rail styling is text, not a pill.** The overlay badge needed a
  contrast background because it sat on art; the rail sits in reserved
  space and renders as dimmed plain text (UIDR-008: no solid fills).
* **`count_placement: :badge`** — the existing overlay pill, retained
  for layouts where a gutter is geometrically impossible or wasteful.
  Overlay badges anchor to **bottom corners only** from now on; the
  top-right position is retired everywhere because it covers the mana
  cost in every layout. `:row` (sideboard splay) keeps bottom-left;
  `:wrap` (draft pool) moves from top-right to a bottom corner.
* **`:row` cannot take a gutter** — cards overlap horizontally, so
  "right of the card" is underneath the next card. The sideboard stays
  on `:badge`. Two count styles across the deck page (rail on the main
  grid, pill on the sideboard) is accepted as layout-driven.
* **`piling: :spread` is unchanged** — physical repetition remains the
  no-numbers alternative; `count_placement` is ignored when spread.
* **The `card_overlay` slot is unchanged** — it still replaces the
  default count presentation entirely (netdeck ownership markers).

### Consequences

* Good, because the mana cost and name are never covered — the visible
  strip of every stacked card is fully legible.
* Good, because counts scan like a decklist: eyes run down one rail
  instead of hunting badges on card corners.
* Good, because placement is now spec data — the per-user render
  preference UIDR-012 anticipated is a persisted `ViewSpec` away.
* Bad, because the rail costs each gutter column ~1–1.5rem of card
  width; with eight mana-value columns side by side every card gets
  slightly smaller.
* Neutral, because "blank rail = one copy" is a convention to learn,
  though it matches the existing convention for reading a splay.
