# MTGA Client Card Database — Design Spec

## Problem

The image cache looks up Scryfall cards by `arena_id` to find image URLs, but ~2% of arena_ids don't exist in Scryfall's bulk data. Meanwhile, the MTGA client itself has a `Raw_CardDatabase` SQLite file with 100% coverage of every arena_id — including names, set codes, and collector numbers. Using this as the primary card identity source and looking up Scryfall images by `(set, collector_number)` gives us 100% coverage.

## Solution

### 1. `cards_mtga_cards` table

New table owned by the `Cards` context. Populated from the MTGA client's `Raw_CardDatabase` SQLite file.

**Typed columns:**

| Column | Type | Source |
|--------|------|--------|
| `arena_id` | integer, PK, unique | `Cards.GrpId` |
| `name` | string | `Localizations_enUS.Loc` (via `TitleId`, `Formatted=1`) |
| `expansion_code` | string | `Cards.ExpansionCode` |
| `collector_number` | string | `Cards.CollectorNumber` |
| `rarity` | integer | `Cards.Rarity` (0-5 enum) |
| `colors` | string | `Cards.Colors` |
| `types` | string | `Cards.Types` |
| `is_token` | boolean | `Cards.IsToken` |
| `is_digital_only` | boolean | `Cards.IsDigitalOnly` |
| `art_id` | integer | `Cards.ArtId` (for future art lookup) |
| `power` | string | `Cards.Power` |
| `toughness` | string | `Cards.Toughness` |

**Indexes:** unique on `arena_id`, index on `expansion_code`, index on `name`.

### 2. `Scry2.Cards.MtgaClientData` module

Reads the MTGA `Raw_CardDatabase` SQLite file, joins `Cards` to `Localizations_enUS` for English names, and upserts into `cards_mtga_cards`.

**Location of source DB:** Discovered by scanning the MTGA data directory for `Raw_CardDatabase_*.mtga` files. The filename includes a hash that changes with MTGA updates. Configurable via `Scry2.Config` key `:mtga_data_dir` (default: derived from the MTGA installation path).

**Import strategy:** Read directly from the MTGA SQLite file using a second Ecto repo or raw SQLite queries (via `Exqlite`). Upsert by `arena_id`. Idempotent — safe to re-run after MTGA updates.

**Public API:**
- `run(opts \\ [])` — imports all cards. Returns `{:ok, %{imported: n}}`.
- `find_database_path()` — locates the `Raw_CardDatabase_*.mtga` file.

### 3. Update `ImageCache`

Change image download logic:
- **Old:** Look up `ScryfallCard` by `arena_id` → get `image_uris["normal"]` → download
- **New:** Look up `MtgaCard` by `arena_id` → get `(expansion_code, collector_number)` → fetch from Scryfall API `GET /cards/{set}/{number}` → extract `image_uris["normal"]` → download

This replaces the dependency on `cards_scryfall_cards` with `cards_mtga_cards`.

### 4. Context functions

Add to `Scry2.Cards`:
- `get_mtga_card(arena_id)` — lookup by arena_id
- `upsert_mtga_card!(attrs)` — upsert by arena_id
- `mtga_card_count()` — total count

### Files

| File | Action | Change |
|------|--------|--------|
| `priv/repo/migrations/*_create_cards_mtga_cards.exs` | Create | Table + indexes |
| `lib/scry_2/cards/mtga_card.ex` | Create | Schema |
| `lib/scry_2/cards/mtga_client_data.ex` | Create | Import module |
| `lib/scry_2/cards.ex` | Modify | Add MTGA card context functions |
| `lib/scry_2/cards/image_cache.ex` | Modify | Use MTGA card data for Scryfall image lookup |
| `lib/scry_2/config.ex` | Modify | Add `:mtga_data_dir` config key |
| `defaults/scry_2.toml` | Modify | Add MTGA data dir config |
| `test/scry_2/cards/mtga_client_data_test.exs` | Create | Import tests |
| `test/support/factory.ex` | Modify | Add `build_mtga_card`, `create_mtga_card` |
