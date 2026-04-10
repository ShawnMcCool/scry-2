# 031 — Decks context owns its match outcome projection

Date: 2026-04-09
Status: Accepted

## Context

The Decks section needs win rate and performance stats per deck. That data lives across two contexts: deck identity in `deck_submitted`/`deck_updated` events, and match outcomes in `match_created`/`match_completed` events.

A cross-context join (`decks_decks` → `matches_matches`) would be simpler to query but violates the bounded context rule — no context may query another context's tables directly.

## Decision

The Decks projector subscribes to `match_created`, `match_completed`, and `game_completed` domain events in addition to deck events, and materialises the subset of match outcome data it needs into its own `decks_match_results` table. This table is a Decks-owned read model keyed on `(mtga_deck_id, mtga_match_id)`.

All Decks stats queries stay within `decks_*` tables.

## Consequences

- **No cross-context DB joins** — the bounded context rule is preserved for all stats queries.
- **Projector claims more slugs** — `match_created`, `match_completed`, `game_completed` are claimed alongside deck events.
- **Slight duplication** — a subset of match fields (format_type, won, on_play, player_rank) are stored in both `matches_matches` and `decks_match_results`. This is intentional: each projection serves its owner's query shape.
- **Pattern for future contexts** — any context that needs performance metrics per entity should follow this same pattern: own a `<context>_match_results` projection rather than joining into `matches_*`.
