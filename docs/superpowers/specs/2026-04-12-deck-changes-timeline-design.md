# Deck Changes Timeline — Design Spec

## Context

The deck detail page has three tabs: Overview, Matches, and Changes. The Changes tab is currently a stub showing raw `DeckUpdated` domain events with just a name, date, and card count. It needs to become a rich visual timeline showing what cards were added/removed between deck versions, per-version performance stats, mana curve shifts, and interleaved match results.

Additionally, MTGA fires `DeckUpdated` events even when nothing changed (opening the deck editor, game sync). Analysis of the current data shows 22 `DeckUpdated` events across all decks but only 1 represents an actual card change. These no-ops pollute the domain event log and must be filtered at ingest time.

## Design

### 1. Filter no-op DeckUpdated at ingest (SnapshotConvert)

`SnapshotConvert` already handles the pattern of "diff a snapshot event, skip if unchanged, convert if changed." DeckUpdated plugs into this existing infrastructure.

**Key design:** `snapshot_state["deck_updated"]` stores a **map of `{deck_id => card_list_key}`** rather than a single key, since multiple decks can be updated independently. The card list key is `{normalized_main_deck, normalized_sideboard}` where normalization sorts by arena_id.

Add a `convert/2` clause for `DeckUpdated` in `SnapshotConvert`:
- Extract `deck_id` from the event
- Look up `deck_map[deck_id]` from the previous key (a map, defaulting to `%{}` on first sight)
- Compute `card_key = {normalize(main_deck), normalize(sideboard)}`
- If `card_key == previous_card_key` → return `:unchanged`
- If different → compute diffs, enrich the event, return `{:converted, updated_deck_map, [enriched_event]}`

The catch-all `convert(_event, _previous_key) -> :passthrough` clause currently handles DeckUpdated, sending it through to SnapshotDiff (where it's not registered, so it passes through again and always appends). The new clause intercepts DeckUpdated before the catch-all.

**Files:**
- `lib/scry_2/events/snapshot_convert.ex` — add `convert/2` for DeckUpdated, private helpers `normalize_card_list/1` and `compute_card_diff/2`
- `lib/scry_2/events/snapshot_diff.ex` — no changes needed (DeckUpdated is handled entirely by SnapshotConvert now)

### 2. Enrich DeckUpdated with diff fields

Add four new optional fields to the `DeckUpdated` struct:

```
main_deck_added    :: [%{arena_id, count}]  — cards added or increased in count
main_deck_removed  :: [%{arena_id, count}]  — cards removed or decreased in count
sideboard_added    :: [%{arena_id, count}]
sideboard_removed  :: [%{arena_id, count}]
```

All default to `[]`. On first sight of a deck (no previous key), all diff fields are `[]` — it's the initial version, there's nothing to diff against.

The diff algorithm (same pattern as `collection_events/2` in SnapshotConvert):
- Convert `[%{arena_id, count}]` to `%{arena_id => count}`
- For each arena_id in new but not old (or with higher count): added entry with the delta
- For each arena_id in old but not new (or with lower count): removed entry with the delta

The enriched event is what gets persisted to `domain_events` and broadcast on `domain:events`.

**Files:**
- `lib/scry_2/events/deck/deck_updated.ex` — add 4 fields to struct, typespec, and `from_payload/1`

### 3. New projection table: `decks_deck_versions`

Schema:

| Field | Type | Notes |
|-------|------|-------|
| `id` | auto-increment | Primary key |
| `mtga_deck_id` | string, not null | FK-free reference to deck |
| `version_number` | integer, not null | Auto-incremented per deck (1, 2, 3...) |
| `deck_name` | string | Name at time of this version |
| `action_type` | string | "Updated", "Cloned", "CopyLimited" |
| `main_deck` | map | Full snapshot `%{"cards" => [...]}` |
| `sideboard` | map | Full snapshot `%{"cards" => [...]}` |
| `main_deck_added` | map | `%{"cards" => [...]}` (from enriched event) |
| `main_deck_removed` | map | `%{"cards" => [...]}` |
| `sideboard_added` | map | `%{"cards" => [...]}` |
| `sideboard_removed` | map | `%{"cards" => [...]}` |
| `match_wins` | integer, default 0 | Pre-computed stats |
| `match_losses` | integer, default 0 | |
| `on_play_wins` | integer, default 0 | |
| `on_play_losses` | integer, default 0 | |
| `on_draw_wins` | integer, default 0 | |
| `on_draw_losses` | integer, default 0 | |
| `occurred_at` | utc_datetime, not null | When this version was created |
| `inserted_at` / `updated_at` | timestamps | |

Indexes:
- `unique_index([:mtga_deck_id, :version_number])`
- `index([:mtga_deck_id])`
- `index([:occurred_at])` — for version-match bucketing queries

**Files:**
- `priv/repo/migrations/YYYYMMDD_create_decks_deck_versions.exs` — new migration
- `lib/scry_2/decks/deck_version.ex` — new Ecto schema

### 4. Projection logic in DeckProjection

**On `DeckUpdated`:** After the existing deck upsert, also create a version row:
- Compute `version_number` as `max(existing versions for deck) + 1`
- Map the enriched event's diff fields into the version row
- Upsert by `(mtga_deck_id, version_number)` for replay idempotency

**On `MatchCompleted`:** After the existing match result enrichment, also update version stats:
- For each deck in the match, find the **active version** at `match.started_at` — the latest version with `occurred_at <= started_at`
- Increment the appropriate win/loss and play/draw counters on that version row
- If no version exists for the deck (match predates first DeckUpdated), skip

Add `Scry2.Decks.DeckVersion` to `projection_tables` (before `Deck` for FK-safe delete order on rebuild).

**Files:**
- `lib/scry_2/decks/deck_projection.ex` — extend `project(%DeckUpdated{})` and `project(%MatchCompleted{})`

### 5. Decks context API

New public functions:

- `upsert_deck_version!/1` — upsert by `(mtga_deck_id, version_number)`
- `next_version_number/1` — `MAX(version_number) + 1` for a deck, returns 1 if none exist
- `get_deck_versions/1` — all versions for a deck, ordered by `version_number DESC`
- `get_active_version_at/2` — latest version where `occurred_at <= timestamp` for a deck
- `increment_version_stats!/3` — find active version for a match's start time, increment counters
- `get_matches_by_version/1` — returns `%{version_number => [match_result]}` for interleaving matches in the timeline

**Files:**
- `lib/scry_2/decks.ex` — new functions
- `lib/scry_2/decks.ex` — remove `get_deck_evolution/1` (replaced by `get_deck_versions/1`)

### 6. UI: Compact vertical timeline

The changes tab renders a vertical timeline (newest first):

**Version entries:**
- Purple dot + vertical line connector
- Header: "Version N" + human-readable date (e.g. "April 10, 2026 — 1:01 PM")
- Card diff section: side-by-side "Added" (green) and "Removed" (red) columns
  - Each card rendered with `<.card_image>` component, green/red border, count badge (+2, −1)
  - Sideboard changes shown in a smaller row below main deck changes
- Per-version stats inline: record (W-L), on-play win rate, on-draw win rate
- Inline mini mana curve comparison: tiny before/after bar pairs for each CMC bucket
- Initial version (version 1) shows "Initial version" with card count, no diff

**Between version entries:**
- Subtle interleaved match summary: "3 matches played (2W–1L)"
- Expandable via JS.toggle to show individual match rows (opponent, result, format)

**Data loading in `load_deck_detail/3` when `tab == :changes`:**
- Fetch versions via `Decks.get_deck_versions/1`
- Fetch matches grouped by version via `Decks.get_matches_by_version/1`
- Collect all arena_ids from version diffs + snapshots for image caching
- Resolve card names via `Cards.list_by_arena_ids/1`

**Files:**
- `lib/scry_2_web/live/decks_live.ex` — rewrite `changes_tab` component, update `load_deck_detail/3`, update assigns
- `lib/scry_2_web/live/decks_helpers.ex` — add `version_mana_curve_data/3` (before/after curve for a version)
- `lib/scry_2_web/components/card_components.ex` — add `card_diff_image/1` component (card_image wrapped with colored border + delta badge)

### 7. Edge cases

| Case | Handling |
|------|----------|
| First version (no previous) | Diff fields all `[]`, UI shows "Initial version" with card count |
| No-op DeckUpdated | Filtered by SnapshotConvert, never persisted |
| Deck rename without card change | Filtered as no-op (key only includes card lists, not name) |
| Match before first version | `get_active_version_at` returns nil, skip stats attribution |
| Version with no matches | Stats all 0, UI shows "0-0" or "No matches" |
| Replay/rebuild | Projection tables truncated, versions rebuilt from enriched events in order |
| Same-timestamp events | Version numbers assigned sequentially by projection order |
| BO3 sideboard changes mid-match | DeckSubmitted events, not DeckUpdated — no new versions created |

### 8. Existing domain events in the database

There are 22 existing `DeckUpdated` events in `domain_events`, almost all no-ops. After implementing this feature, a reingest (`reset_all!` + restart watcher) will reprocess all raw events through the updated SnapshotConvert, correctly filtering no-ops and enriching real changes. The `decks_deck_versions` projection will be populated from scratch.

## Verification

1. **Unit tests:** SnapshotConvert DeckUpdated clause — test no-op filtering, first-sight passthrough, diff computation with various card list changes
2. **Unit tests:** DeckProjection — test version creation from DeckUpdated, match stats attribution from MatchCompleted
3. **Unit tests:** Decks context — test `get_deck_versions/1`, `get_active_version_at/2`, `increment_version_stats!/3`
4. **Integration:** Run `mix test` — zero warnings, all pass
5. **Runtime:** After reingest, verify via tidewave SQL that `decks_deck_versions` has the correct number of versions (should be much fewer than the 22 raw events)
6. **Runtime:** Navigate to a deck's Changes tab, verify the timeline renders with card images, stats, and match interleaving
7. **Runtime:** Check tidewave logs for any errors during projection
