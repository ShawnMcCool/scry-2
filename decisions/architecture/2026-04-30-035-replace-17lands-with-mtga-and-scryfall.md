---
status: accepted
date: 2026-04-30
---
# Replace 17lands card data with MTGA + Scryfall synthesis

## Context and Problem Statement

Until April 2026, scry_2 treated `17lands-public.s3.amazonaws.com/analysis_data/cards/cards.csv` as the source of truth for card reference data — names, rarity, color identity, mana value, types, set listings. `Scryfall` was layered on top to backfill `arena_id` onto 17lands rows, since the CSV does not include MTGA's identifier.

Two issues with that arrangement:

1. **Third-party single point of failure.** 17lands is a small specialised analytics service. If they change the CSV format, rate-limit, or shut down, scry_2's primary card list goes dark.
2. **Redundancy.** scry_2 already pulls two superset sources on independent schedules:
   - `Scry2.Cards.MtgaClientData` reads the user's local `Raw_CardDatabase_*.mtga` SQLite. This is the canonical Arena card list — every `arena_id` MTGA assigns has an entry there. Zero third-party dependency: it's the user's own game install.
   - `Scry2.Cards.Scryfall` streams the Scryfall Default Cards bulk JSON. Provides oracle text, image URIs, type lines, color identity, and coverage of rotated cards no longer in the local MTGA DB.

   Combined, those two sources cover 100% of the fields 17lands provides, with better accuracy. The 17lands path was duplicating work the codebase was already doing.

A redesign was needed that removed the 17lands dependency, kept `arena_id` as the canonical identity, and lost no card data in the process.

## Decision Outcome

Chosen option: **synthesise `cards_cards` from MTGA client SQLite + Scryfall bulk data, indexed by `arena_id`**, because it eliminates the 17lands dependency, leans on data sources scry_2 already imports, and keeps Scryfall — the de facto MTG metadata standard, community-funded since 2017 — as the single remaining third-party.

The new pipeline:

1. `Scry2.Cards.MtgaClientData.run/0` — populates `cards_mtga_cards`.
2. `Scry2.Cards.Scryfall.run/0` — populates `cards_scryfall_cards`.
3. `Scry2.Cards.Synthesize.run/0` — joins both indexes by `arena_id`, builds attrs with Scryfall-preferred enrichable fields, and upserts `cards_cards`. Disposable read model — drop and rebuild any time.

The migration `20260430010000_replace_seventeen_lands_with_synthesis.exs` reconciles existing rows by joining `cards_mtga_cards` on `(name, expansion_code)` to backfill missing `arena_id`s, archives any unresolved rows to `cards_cards_archive` (paper-only printings 17lands listed but Arena never had — safe to remove from the live model, preserved for forensic completeness), then drops `lands17_id` and `raw` columns. `arena_id` is enforced via unique index plus `validate_required` on the changeset; SQLite doesn't support `ALTER COLUMN` so the DB-level NOT NULL is replaced with the equivalent app-level guarantees.

Cron schedule (config/config.exs):

| Time (UTC)    | Worker                             |
|---------------|------------------------------------|
| Daily 04:30   | `PeriodicallyImportMtgaClientCards` |
| Sunday 05:00  | `PeriodicallyImportScryfallCards`   |
| Daily 05:30   | `PeriodicallySynthesizeCards`       |

### Consequences

* **Good** — no third-party dependency for the canonical Arena card list. The user's own game files supply it.
* **Good** — cleaner pipeline. One synthesis step replaces 17lands import + Scryfall arena_id backfill + MTGA client name fallback. The "two-pass backfill" code is gone.
* **Good** — `arena_id` is now a hard identity contract on `cards_cards` (unique index + required-on-changeset). Eliminates the nullable-arena_id state that 17lands forced.
* **Good** — the 17lands `is_booster` heuristic is replaced by Scryfall's `booster` field (oracle-correct, no string-parsing rules).
* **Good** — fewer cron entries, simpler health/freshness story.
* **Bad** — Scryfall remains a third-party. If Scryfall went down, scry_2 would lose oracle text and image URIs but keep the canonical card list (MTGA SQLite). Acceptable: oracle text is a UX nicety, not a correctness requirement.
* **Bad** — users without MTGA installed get no card data. This was already true: scry_2 is an MTGA-companion app and useless without MTGA.
* **Neutral** — historical 17lands rows that never had an `arena_id` are archived rather than retained in `cards_cards`. They are unreferenced (events use arena_id by value per ADR-014, no FKs to `cards_cards.id`) and were never useful for live queries.

This decision supersedes the implicit "17lands is the source of truth" stance previously documented in CLAUDE.md.
