---
status: accepted
date: 2026-07-11
---
# Deck Rendering Engine

## Context and Problem Statement

Every surface that shows a list of Magic cards grew its own template: the
deck page's composition (type columns, CMC image stacks, sideboard splay),
the match page's submitted list, the netdeck decklist with ownership
markers, the draft pool, pick packs, revealed cards, and version diffs.
Each duplicated grouping logic, count badges, image sizing, and hover
wiring; visual changes had to be applied N times and drifted. The user
also wants to eventually *choose* how a deck renders (grouping, text vs.
images, splay depth) — impossible while each rendering is hardcoded
markup.

## Decision Outcome

Chosen option: "one parameterized rendering engine", because rendering a
card list is one operation with orthogonal choices, and every display in
the app is a point in that parameter space.

* **`Scry2Web.DeckRendering`** is the engine. Pipeline: normalize any
  snapshot shape (`%{"cards" => [...]}`, card-map lists, bare arena_id
  lists) → resolve against the card reference → section per spec →
  present.
* **`ViewSpec`** is runtime data, not component attrs: `group_by`
  (`:none | :type | :broad_type | :mana_value`), `display`
  (`:text | :images`), `piling` (`:piled` merges duplicates behind a
  count badge, `:spread` renders each copy), `layout` (`:columns`
  vertical-splay grid, `:row` horizontal splay, `:wrap` flat), plus
  `splay_depth` and `card_width`. Being a struct means future UI
  controls can build and persist specs without touching the engine.
* **Pages compose views.** `deck_view/1` renders one spec;
  `deck_view_group/1` carries the JS hook that harmonizes card sizes
  across composed views (`:row` splay matches the `:columns` grid).
* **`standard_composition/1`** is the app's default deck presentation —
  mana curve chart, text-by-type with a Sideboard column, image stacks
  by mana value, sideboard splay — defined once, used by the deck,
  match, and netdeck pages.
* **`card_overlay` slot** is the extension point for caller-specific
  per-card annotation (netdeck ownership markers today; picked-card and
  diff markers when those displays converge).
* The mana curve **chart is not an engine view kind** — it is an ECharts
  concern composed alongside; it may become `display: :chart` later.
* **Full convergence**: draft pick packs (picked-card overlay), the
  revealed-cards card (per-zone views), and version diffs (added/removed
  overlays) render through `deck_view` too, using `order: :natural`
  where the input sequence is the fact being displayed (pack contents,
  memory order). Collection browsing (cards, set detail) is deliberately
  out — it renders ownership state of the card pool, not a deck-shaped
  card list.

## Consequences

* Good, because a visual change to card rendering lands once.
* Good, because per-user render preferences become a `ViewSpec` in
  `Settings.Entry` away, not a rewrite.
* Neutral, because the draft pool's condensed grouping survives as
  `:broad_type` — two type vocabularies remain, but both live in the
  engine as named options.
* Bad, because `:columns`/`:row` views must be wrapped in a
  `deck_view_group` for the sizing hook — a composition rule the
  compiler cannot enforce (documented on the component).
