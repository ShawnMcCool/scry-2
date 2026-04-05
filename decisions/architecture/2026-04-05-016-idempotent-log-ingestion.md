# 016. Idempotent log ingestion

Date: 2026-04-05

## Status

Accepted

## Context

The `Player.log` watcher may re-read overlapping byte ranges after a crash or restart (its persisted offset can lag the last fully-processed event by one or more events). The raw-event replay store (ADR-015) is append-safe — events are unique by MTGA's event sequence — but per-event upserts on `matches`, `games`, `drafts`, and `deck_submissions` must not create duplicates.

Additionally, ADR-012 (durable process design) requires that restarting the ingester produce the same eventual state as if it had never stopped. This is only possible if every downstream write is idempotent with respect to the same input event.

## Decision

Every match, game, draft, and deck upsert uses the MTGA-provided ID as its conflict target:

- `matches_matches.mtga_match_id`
- `matches_games.mtga_game_id`
- `drafts_drafts.mtga_draft_id`
- `matches_deck_submissions.mtga_deck_id`

Writes go through `Repo.insert_all/3` (or an equivalent `on_conflict` path) with `on_conflict: {:replace_all_except, [:id, :inserted_at]}` and `conflict_target: [:mtga_<entity>_id]`. Reprocessing any range of `mtga_logs_events` must yield bit-identical downstream state (modulo `updated_at` timestamps).

## Consequences

- Slightly more complex upsert logic than naive inserts.
- Safe to reprocess events: re-running the parser over historical events produces the same output state.
- Safe to recover from partial writes: a crash mid-batch leaves no duplicate rows.
- Safe to run migrations over historical data: backfills and corrections can replay event ranges without fear of doubling up.
- Combined with ADR-012 (durability) and ADR-015 (raw replay), this closes the loop on restart-safety for the whole ingestion pipeline.
