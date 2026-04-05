# 014. `arena_id` as the stable join key

Date: 2026-04-05

## Status

Accepted

## Context

MTGA assigns every card a 5-digit integer `arena_id`. Every log event in `Player.log` references cards by `arena_id` — draft picks, deck submissions, game objects. This is the identifier MTGA itself uses to denote a specific card printing.

The 17lands public cards.csv is the source of truth for card reference data, but it uses its own `id` column (`lands17_id`) and does not always include `arena_id`. We backfill missing `arena_id` values via the Scryfall API. All downstream joins — draft picks to cards, deck submissions to cards, match decks to cards — require a stable, never-reassigned identifier on the card side of the join.

If `arena_id` could change (e.g., a 17lands refresh presenting a different value, or a careless overwrite during a Scryfall backfill), every historical log event pointing at that card would silently land on the wrong row or no row at all.

## Decision

`cards_cards.arena_id` is the canonical join key for all log-derived data. It is unique, indexed, and once set for a given card is **never** updated.

- The primary upsert target for `cards_cards` is `lands17_id` — that is how 17lands refreshes are applied.
- `arena_id` is set once per row, via a separate backfill path (`Scry2.Cards.ScryfallBackfill`). If a backfill discovers an `arena_id` that conflicts with an existing row, it must log a warning and skip — never clobber.
- New printings with new `arena_id` values create new rows; old `arena_id` values stay stable.
- Queries that join log events to cards always join on `arena_id`, never on `lands17_id`.

## Consequences

- Fixed-meaning identifier makes queries simple and correct — once a draft pick is ingested, its card reference never moves.
- The upsert strategy is slightly more complex: two separate write paths (one for 17lands refreshes keyed on `lands17_id`, one for Scryfall backfills keyed on `arena_id`).
- Conflicts between data sources become visible as warnings instead of silent corruption.
- This is the single most important data-integrity invariant for card identity in Scry2.
