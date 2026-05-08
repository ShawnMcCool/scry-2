---
status: accepted
date: 2026-05-08
---
# Synthesise cards by `(set_code, collector_number)`, not `arena_id`

## Context and Problem Statement

`Scry2.Cards.Synthesize` produces `cards_cards` (the canonical Arena
card read model) by joining `cards_mtga_cards` (MTGA's local card DB)
with `cards_scryfall_cards` (Scryfall bulk data). Until this ADR, that
join was keyed on `arena_id`.

`arena_id` is a defensible row identity for `cards_cards` and is the
correct join key for **log-derived** data (events, projections) per
ADR-014 — but it is the wrong choice as the synthesis-time join key
between the two reference sources, because **Scryfall populates
`arena_id` weeks-to-months late for new sets**.

Concretely, on 2026-05-08 the Scryfall mirror has full metadata for
SOS (Secrets of Strixhaven, 369 cards), TMT (Teenage Mutant Ninja
Turtles, 320 cards), and TLA (Avatar: The Last Airbender, 394 cards)
— but **zero rows in any of those sets have `arena_id` populated**.
Today's `Synthesize.run/1` filters `cards_scryfall_cards` to
`arena_id != nil` before building the join index, so the join misses
for every card in those sets.

User-visible symptoms:

* `cards_sets` rows for SOS / TMT / TLA have `name = code` (bare
  3-letter code) and `released_at = nil`. The Collection grid labels
  the tile `SOS` instead of *Secrets of Strixhaven* and sorts the
  tile to the bottom because the sort prefers dated sets.
* Cards in those sets have only MTGA's data on `cards_cards`:
  degraded `type_line`, no Scryfall `color_identity`, no Scryfall
  rarity normalisation.

This isn't a fallback to add — it's a consistency fix. The rest of
the cards context **already** uses `(set_code, collector_number)` as
the cross-source join key:

* `Cards.list_cards/1` deduplication (lib/scry_2/cards.ex:366–371)
  joins MTGA → Scryfall by `(expansion_code, collector_number)`.
* `Cards.get_image_url_for_arena_id/1` second-pass fallback
  (lib/scry_2/cards.ex:436–438) does the same.

The synthesizer was the **last** place still joining by `arena_id`,
and was therefore the source of the inconsistency the user observed.
Coverage check (one-off query on 2026-05-08): 0 missing `set_code`
in 114,160 Scryfall rows, 0 missing `collector_number`; 4 missing
`collector_number` in 24,928 MTGA rows. `(set_code,
collector_number)` is universally present in both sources to within
a rounding error.

## Decision Outcome

Chosen option: **synthesis joins MTGA → Scryfall primarily by
`(upcase(set_code), collector_number)`**, because it is the universal
MTG printing identifier present in both sources from day one of every
set release, while `arena_id` lags Scryfall ingestion by weeks.

`arena_id` remains the unique row identity of `cards_cards` and the
canonical join key for log-derived data (events, projections) per
ADR-014, **which this ADR does not modify**. Events still join
`cards_cards` by `arena_id`. The change is scoped to synthesis-time
join semantics only.

`cards_cards` gains a persisted `collector_number` column, kept in
sync by synthesis, so downstream consumers can read the universal
printing identifier without joining `cards_mtga_cards`.

The synthesizer is decomposed from a 340-LOC single module into a
thin orchestrator plus three pure sub-modules — `Pairing`,
`MergeFields`, `SetMetadata` — each independently unit-tested. The
`(set, number)`-primary join lives in `Pairing` with explicit
token-skip and missing-data rules.

### Tokens

Tokens (MTGA `is_token=true`, Scryfall `layout="token"`) are
excluded from the primary join. MTGA emits tokens under the parent
set's code (e.g. SOS#1 is both *The Dawning Archaic* AND a *Copy*
token); Scryfall keeps tokens under prefixed token-set codes
(`TSOS`, `TLCI`, etc.), not the parent set. So a token's `(SOS, 1)`
either misses entirely or — worse — silently matches the parent
card and enriches the token with the parent's data. `Pairing.for_mtga`
returns `nil` for any `is_token: true` MTGA card; the rotated pass
filters Scryfall rows by `layout != "token"` for the same reason.
Tokens synthesise from MTGA data only.

### DFC suffixes

If Scryfall uses collector-number suffixes for double-faced cards
(`123a` / `123b`) that MTGA doesn't emit, the lookup misses and the
card synthesises MTGA-only. Acceptable degradation; affects a small
number of cards per set.

### Consequences

* Good, because set names and release dates populate for every
  Scryfall-tracked set regardless of `arena_id` presence. SOS / TMT /
  TLA tiles render correctly today; future Standard sets work from
  release day onward.
* Good, because cards from new sets get full Scryfall enrichment
  (proper `types`, `color_identity`, `rarity`, `mana_value`,
  `is_booster`) immediately, instead of waiting weeks for Scryfall to
  backfill `arena_id`.
* Good, because the synthesizer is now consistent with
  `Cards.list_cards/1` and `Cards.get_image_url_for_arena_id/1`. One
  cross-source join key for the whole context.
* Good, because the modular decomposition makes the pipeline
  self-evident and unit-testable: `Pairing` (which Scryfall row pairs
  with which MTGA card), `MergeFields` (how the two are merged into
  attrs), `SetMetadata` (how per-set name/date is extracted).
* Good, because `cards_cards.collector_number` is now persisted, so
  downstream code can read the universal printing identifier without
  joining `cards_mtga_cards`.
* Bad, because DFC cards where Scryfall uses collector-number suffixes
  MTGA doesn't emit will miss the join and synthesise MTGA-only. Small
  per-set blast radius; documented behaviour.
* Bad, because `decode_mtga_types/1` is now duplicated in
  `Cards.list_by_arena_ids/1` and in `MergeFields`. Drift risk;
  consolidate in a follow-up.
* Bad, because the rotated-pass token guard (`layout != "token"`) and
  the primary-pass token guard (`is_token == true`) are two separate
  rules in two places. Acceptable — they protect different sides — but
  worth keeping co-documented.

## Related

* ADR-014 (arena_id as stable key) — unchanged. Events keep joining
  `cards_cards` by `arena_id`. This ADR narrows ADR-014's scope to
  log-derived data, where it was always correct.
* ADR-035 (replace 17lands with MTGA + Scryfall) — established
  `Synthesize` as the single producer of `cards_cards`.
* Memory note `feedback_self_documenting_pipelines` — the modular
  decomposition (Pairing / MergeFields / SetMetadata) follows this
  rule: each stage's module @moduledoc states its input → output
  contract, and `Synthesize`'s @moduledoc lists the stages.
