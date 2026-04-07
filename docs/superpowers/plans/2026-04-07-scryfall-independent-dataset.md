# Scryfall Independent Dataset — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Store Scryfall bulk data as an independent dataset in `cards_scryfall_cards`, separate from the 17lands dataset in `cards_cards`. Both datasets can be queried independently and joined via `arena_id`.

**Architecture:** New `ScryfallCard` schema owns `cards_scryfall_cards` with typed columns for the most useful fields and a `raw` JSON column preserving all 60+ Scryfall fields. The existing `Scry2.Cards.Scryfall` module is refactored to persist every card into this table during its stream pass, in addition to continuing the `arena_id` backfill on 17lands cards. The table is disposable — truncate and rebuild from `Scryfall.run()`.

**Tech Stack:** Ecto (schema + migration), Jaxon (stream parsing), Req (HTTP), SQLite.

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `lib/scry_2/cards/scryfall_card.ex` | Create | Schema for `cards_scryfall_cards` |
| `lib/scry_2/cards/scryfall.ex` | Modify | Persist Scryfall cards during stream + continue arena_id backfill |
| `lib/scry_2/cards.ex` | Modify | Add Scryfall query functions to context |
| `priv/repo/migrations/*_create_cards_scryfall_cards.exs` | Create | Table + indexes |
| `test/scry_2/cards/scryfall_test.exs` | Modify | Add persistence tests, update existing tests for new return stats |
| `test/scry_2/cards_test.exs` | Modify | Add context query tests for Scryfall cards |
| `test/support/factory.ex` | Modify | Add `build_scryfall_card/1` and `create_scryfall_card/1` |

---

### Task 1: Migration — `cards_scryfall_cards` table

**Files:**
- Create: `priv/repo/migrations/<timestamp>_create_cards_scryfall_cards.exs`

- [ ] **Step 1: Generate and write migration**

```bash
mix ecto.gen.migration create_cards_scryfall_cards
```

Write migration body:

```elixir
def change do
  create table(:cards_scryfall_cards) do
    add :scryfall_id, :string, null: false
    add :oracle_id, :string
    add :arena_id, :integer
    add :name, :string, null: false
    add :set_code, :string, null: false
    add :collector_number, :string
    add :type_line, :string
    add :oracle_text, :text
    add :mana_cost, :string
    add :cmc, :float
    add :colors, :string, default: ""
    add :color_identity, :string, default: ""
    add :rarity, :string
    add :layout, :string
    add :image_uris, :map
    add :raw, :map

    timestamps(type: :utc_datetime)
  end

  create unique_index(:cards_scryfall_cards, [:scryfall_id])
  create index(:cards_scryfall_cards, [:arena_id])
  create index(:cards_scryfall_cards, [:name])
  create index(:cards_scryfall_cards, [:set_code])
  create index(:cards_scryfall_cards, [:set_code, :collector_number])
end
```

- [ ] **Step 2: Run migration**

```bash
mix ecto.migrate
```

Expected: table created with 5 indexes.

- [ ] **Step 3: Commit**

```bash
jj describe -m "feat: add cards_scryfall_cards table for independent Scryfall dataset"
```

---

### Task 2: Schema — `ScryfallCard`

**Files:**
- Create: `lib/scry_2/cards/scryfall_card.ex`

- [ ] **Step 1: Write the schema**

```elixir
defmodule Scry2.Cards.ScryfallCard do
  @moduledoc """
  Schema for `cards_scryfall_cards` — an independent copy of Scryfall's
  card reference data.

  This table is **disposable**: it can be truncated and fully rebuilt from
  a single `Scry2.Cards.Scryfall.run()` call. No other table holds foreign
  keys to it.

  ## Typed columns

  The typed columns below cover the most commonly queried fields. The `raw`
  column preserves the complete Scryfall JSON (~60 fields per card) for
  forward-compatibility. If you need a new queryable column:

  1. Add the field to this schema and a migration.
  2. The next `Scryfall.run()` will populate it from the `raw` data.
  3. No data loss — the `raw` column already contains every field.

  ## All available Scryfall fields (in `raw`)

  Card identity: `id` (scryfall_id), `oracle_id`, `arena_id`, `mtgo_id`,
  `multiverse_ids`, `cardmarket_id`, `tcgplayer_id`, `object`, `lang`.

  Card content: `name`, `type_line`, `oracle_text`, `mana_cost`, `cmc`,
  `colors`, `color_identity`, `keywords`, `layout`, `flavor_text`.

  Printing: `set`, `set_name`, `set_id`, `set_type`, `collector_number`,
  `rarity`, `released_at`, `reprint`, `variation`, `booster`, `digital`.

  Images: `image_uris` (map with `small`, `normal`, `large`, `png`,
  `art_crop`, `border_crop`), `image_status`, `highres_image`.
  Note: DFCs store images under `card_faces[].image_uris` instead.

  Legalities: `legalities` (map of format → status, ~21 formats).

  Prices: `prices` (map of `usd`, `usd_foil`, `eur`, `tix`).

  Art: `artist`, `artist_ids`, `illustration_id`, `frame`, `full_art`,
  `textless`, `border_color`, `story_spotlight`.

  Booleans: `foil`, `nonfoil`, `oversized`, `promo`, `reserved`,
  `game_changer`.

  Games: `games` (list: `paper`, `mtgo`, `arena`).

  External links: `scryfall_uri`, `uri`, `rulings_uri`,
  `prints_search_uri`, `purchase_uris`, `related_uris`.

  Related cards: `all_parts` (list of related card objects).

  Card faces (DFCs): `card_faces` (list of face objects with their own
  `name`, `mana_cost`, `oracle_text`, `image_uris`, etc.).
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "cards_scryfall_cards" do
    field :scryfall_id, :string
    field :oracle_id, :string
    field :arena_id, :integer
    field :name, :string
    field :set_code, :string
    field :collector_number, :string
    field :type_line, :string
    field :oracle_text, :string
    field :mana_cost, :string
    field :cmc, :float
    field :colors, :string, default: ""
    field :color_identity, :string, default: ""
    field :rarity, :string
    field :layout, :string
    field :image_uris, :map
    field :raw, :map

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for upserting from Scryfall bulk data.
  """
  def changeset(card, attrs) do
    card
    |> cast(attrs, [
      :scryfall_id,
      :oracle_id,
      :arena_id,
      :name,
      :set_code,
      :collector_number,
      :type_line,
      :oracle_text,
      :mana_cost,
      :cmc,
      :colors,
      :color_identity,
      :rarity,
      :layout,
      :image_uris,
      :raw
    ])
    |> validate_required([:scryfall_id, :name, :set_code])
    |> unique_constraint(:scryfall_id)
  end
end
```

- [ ] **Step 2: Verify compilation**

```bash
mix compile --no-optional-deps
```

Expected: compiles with zero warnings.

- [ ] **Step 3: Commit**

```bash
jj describe -m "feat: add ScryfallCard schema for independent Scryfall dataset"
```

---

### Task 3: Context functions + tests

**Files:**
- Modify: `lib/scry_2/cards.ex`
- Modify: `test/scry_2/cards_test.exs`
- Modify: `test/support/factory.ex`

- [ ] **Step 1: Add factory helpers to `test/support/factory.ex`**

In the `build_*` section:

```elixir
def build_scryfall_card(attrs \\ %{}) do
  defaults = %{
    scryfall_id: "scryfallid-" <> random_suffix(),
    oracle_id: "oracleid-" <> random_suffix(),
    arena_id: nil,
    name: "Test Scryfall Card",
    set_code: "tst",
    collector_number: "1",
    type_line: "Creature — Test",
    oracle_text: "Test oracle text.",
    mana_cost: "{1}{W}",
    cmc: 2.0,
    colors: "W",
    color_identity: "W",
    rarity: "common",
    layout: "normal",
    image_uris: %{"normal" => "https://example.com/card.jpg"},
    raw: %{}
  }

  struct(Scry2.Cards.ScryfallCard, Map.merge(defaults, Map.new(attrs)))
end
```

In the `create_*` section:

```elixir
def create_scryfall_card(attrs \\ %{}) do
  attrs
  |> build_scryfall_card()
  |> Map.from_struct()
  |> Map.drop([:__meta__])
  |> then(&Cards.upsert_scryfall_card!/1)
end
```

Add `ScryfallCard` to the alias list and `@compile` no-warn list as needed.

- [ ] **Step 2: Write failing tests for context functions in `test/scry_2/cards_test.exs`**

```elixir
describe "upsert_scryfall_card!/1" do
  test "creates a new scryfall card" do
    card =
      Cards.upsert_scryfall_card!(%{
        scryfall_id: "abc-123",
        name: "Lightning Bolt",
        set_code: "lci",
        rarity: "common",
        raw: %{"id" => "abc-123"}
      })

    assert card.scryfall_id == "abc-123"
    assert card.name == "Lightning Bolt"
  end

  test "updates an existing card by scryfall_id (idempotent)" do
    first =
      Cards.upsert_scryfall_card!(%{
        scryfall_id: "abc-456",
        name: "Old Name",
        set_code: "lci",
        raw: %{}
      })

    second =
      Cards.upsert_scryfall_card!(%{
        scryfall_id: "abc-456",
        name: "New Name",
        set_code: "lci",
        raw: %{}
      })

    assert first.id == second.id
    assert second.name == "New Name"
  end
end

describe "get_scryfall_by_arena_id/1" do
  test "returns the scryfall card for a given arena_id" do
    TestFactory.create_scryfall_card(%{arena_id: 91_500, name: "Found"})
    card = Cards.get_scryfall_by_arena_id(91_500)
    assert card.name == "Found"
  end

  test "returns nil for unknown arena_id" do
    assert Cards.get_scryfall_by_arena_id(99_999_999) == nil
  end
end

describe "scryfall_count/0" do
  test "returns the count of scryfall cards" do
    TestFactory.create_scryfall_card(%{name: "Card A"})
    TestFactory.create_scryfall_card(%{name: "Card B"})
    assert Cards.scryfall_count() >= 2
  end
end
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
mix test test/scry_2/cards_test.exs
```

Expected: failures on undefined `upsert_scryfall_card!/1`, `get_scryfall_by_arena_id/1`, `scryfall_count/0`.

- [ ] **Step 4: Implement context functions in `lib/scry_2/cards.ex`**

Update the moduledoc to list `cards_scryfall_cards` as an owned table. Add alias for `ScryfallCard`. Then add:

```elixir
# ── Scryfall Cards ────────────────────────────────────────────────────

@doc "Returns the total Scryfall card count."
def scryfall_count do
  Repo.aggregate(ScryfallCard, :count, :id)
end

@doc "Returns the Scryfall card for the given MTGA arena_id, or nil."
def get_scryfall_by_arena_id(arena_id) when is_integer(arena_id) do
  Repo.get_by(ScryfallCard, arena_id: arena_id)
end

@doc "Returns the Scryfall card for the given scryfall_id, or nil."
def get_scryfall_by_scryfall_id(scryfall_id) when is_binary(scryfall_id) do
  Repo.get_by(ScryfallCard, scryfall_id: scryfall_id)
end

@doc """
Upserts a Scryfall card by `scryfall_id`.
"""
def upsert_scryfall_card!(attrs) do
  attrs = Map.new(attrs)

  case get_scryfall_by_scryfall_id(attrs.scryfall_id) do
    nil ->
      %ScryfallCard{}
      |> ScryfallCard.changeset(attrs)
      |> Repo.insert!()

    existing ->
      existing
      |> ScryfallCard.changeset(attrs)
      |> Repo.update!()
  end
end
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
mix test test/scry_2/cards_test.exs
```

Expected: all pass, zero warnings.

- [ ] **Step 6: Commit**

```bash
jj describe -m "feat: add Scryfall card context functions with upsert and queries"
```

---

### Task 4: Refactor `Scryfall` module to persist cards

**Files:**
- Modify: `lib/scry_2/cards/scryfall.ex`
- Modify: `test/scry_2/cards/scryfall_test.exs`

- [ ] **Step 1: Update test fixtures to include all typed columns**

In `test/scry_2/cards/scryfall_test.exs`, update the module attributes to be realistic Scryfall card objects:

```elixir
@scryfall_mountain %{
  "id" => "scryfallid-mountain-lci",
  "oracle_id" => "oracleid-mountain",
  "name" => "Mountain",
  "set" => "lci",
  "arena_id" => 91_001,
  "collector_number" => "287",
  "type_line" => "Basic Land — Mountain",
  "oracle_text" => "({T}: Add {R}.)",
  "mana_cost" => "",
  "cmc" => 0.0,
  "colors" => [],
  "color_identity" => ["R"],
  "rarity" => "common",
  "layout" => "normal",
  "image_uris" => %{"normal" => "https://example.com/mountain.jpg"}
}

@scryfall_bolt %{
  "id" => "scryfallid-bolt-lci",
  "oracle_id" => "oracleid-bolt",
  "name" => "Lightning Bolt",
  "set" => "lci",
  "arena_id" => 91_002,
  "collector_number" => "154",
  "type_line" => "Instant",
  "oracle_text" => "Lightning Bolt deals 3 damage to any target.",
  "mana_cost" => "{R}",
  "cmc" => 1.0,
  "colors" => ["R"],
  "color_identity" => ["R"],
  "rarity" => "common",
  "layout" => "normal",
  "image_uris" => %{"normal" => "https://example.com/bolt.jpg"}
}

@scryfall_dfc %{
  "id" => "scryfallid-bonecrusher",
  "oracle_id" => "oracleid-bonecrusher",
  "name" => "Bonecrusher Giant // Stomp",
  "set" => "otj",
  "arena_id" => 91_003,
  "collector_number" => "115",
  "type_line" => "Creature — Giant // Instant — Adventure",
  "oracle_text" => "Adventure text",
  "mana_cost" => "{2}{R}",
  "cmc" => 3.0,
  "colors" => ["R"],
  "color_identity" => ["R"],
  "rarity" => "rare",
  "layout" => "adventure",
  "image_uris" => %{"normal" => "https://example.com/bonecrusher.jpg"}
}

@scryfall_no_arena %{
  "id" => "scryfallid-paper-only",
  "oracle_id" => "oracleid-paper",
  "name" => "Paper Only Card",
  "set" => "lci",
  "arena_id" => nil,
  "collector_number" => "999",
  "type_line" => "Creature — Test",
  "oracle_text" => "Not on Arena.",
  "mana_cost" => "{W}",
  "cmc" => 1.0,
  "colors" => ["W"],
  "color_identity" => ["W"],
  "rarity" => "common",
  "layout" => "normal",
  "image_uris" => %{"normal" => "https://example.com/paper.jpg"}
}
```

- [ ] **Step 2: Add tests for Scryfall card persistence**

Add to the `"run/1 with Req.Test stubs"` describe block:

```elixir
test "persists all Scryfall cards (including those without arena_id)" do
  Scryfall.run(
    url: "http://stub.test/catalog",
    req_options: [plug: {Req.Test, Scryfall}]
  )

  # All 4 cards in the stub should be persisted (including paper-only)
  assert Cards.scryfall_count() == 4

  mountain = Cards.get_scryfall_by_arena_id(91_001)
  assert mountain.name == "Mountain"
  assert mountain.set_code == "lci"
  assert mountain.type_line == "Basic Land — Mountain"
  assert mountain.rarity == "common"
  assert mountain.raw["id"] == "scryfallid-mountain-lci"
end

test "persists Scryfall cards idempotently on re-run" do
  opts = [
    url: "http://stub.test/catalog",
    req_options: [plug: {Req.Test, Scryfall}]
  ]

  Scryfall.run(opts)
  Scryfall.run(opts)

  # Still 4 rows — second run updates, doesn't duplicate.
  assert Cards.scryfall_count() == 4
end
```

- [ ] **Step 3: Update `run/1` return stats**

The `run_result` type should now include `persisted` count. Update tests that pattern-match on the return value to account for `persisted`:

```elixir
test "backfills arena_id on matched cards", %{mountain: mountain, bolt: bolt} do
  assert {:ok, %{matched: 2, skipped: 1, persisted: 4}} =
           Scryfall.run(
             url: "http://stub.test/catalog",
             req_options: [plug: {Req.Test, Scryfall}]
           )
  # ... existing assertions
end
```

- [ ] **Step 4: Run tests to verify they fail**

```bash
mix test test/scry_2/cards/scryfall_test.exs
```

Expected: failures — Scryfall cards not being persisted yet.

- [ ] **Step 5: Refactor `Scryfall` module**

Update `@moduledoc` to describe both responsibilities (persist + backfill). Update `parse_card/1` to extract all typed columns and preserve `raw`. Update `process_stream/1` to persist every card via `Cards.upsert_scryfall_card!/1` and then continue the arena_id backfill for cards with arena_ids.

Key changes to `parse_card/1`:

```elixir
def parse_card(%{"id" => scryfall_id, "name" => name, "set" => set} = card)
    when is_binary(scryfall_id) and is_binary(name) and is_binary(set) do
  %{
    scryfall_id: scryfall_id,
    oracle_id: card["oracle_id"],
    arena_id: card["arena_id"],
    name: name,
    set_code: set,
    collector_number: card["collector_number"],
    type_line: card["type_line"],
    oracle_text: card["oracle_text"],
    mana_cost: card["mana_cost"],
    cmc: parse_cmc(card["cmc"]),
    colors: join_list(card["colors"]),
    color_identity: join_list(card["color_identity"]),
    rarity: card["rarity"],
    layout: card["layout"],
    image_uris: card["image_uris"],
    raw: card
  }
end

def parse_card(_), do: nil

defp parse_cmc(nil), do: nil
defp parse_cmc(val) when is_number(val), do: val / 1
defp parse_cmc(_), do: nil

defp join_list(nil), do: ""
defp join_list(list) when is_list(list), do: Enum.join(list)
defp join_list(val) when is_binary(val), do: val
```

Key changes to `process_stream/1` — persist every card, then backfill arena_id for those that have one:

```elixir
defp process_stream(tmp_path) do
  File.stream!(tmp_path, 65_536)
  |> Jaxon.Stream.from_enumerable()
  |> Jaxon.Stream.query([:root, :all])
  |> Enum.reduce(%{matched: 0, skipped: 0, persisted: 0}, fn card_map, stats ->
    case parse_card(card_map) do
      nil ->
        stats

      parsed ->
        Cards.upsert_scryfall_card!(parsed)
        stats = %{stats | persisted: stats.persisted + 1}

        if parsed.arena_id do
          front_name = parsed.name |> String.split(" // ") |> hd()
          set_code = String.upcase(parsed.set_code)
          maybe_backfill(front_name, set_code, parsed.arena_id, stats)
        else
          %{stats | skipped: stats.skipped + 1}
        end
    end
  end)
end
```

Note: the DFC name splitting (`" // "`) and set code upcasing move out of `parse_card/1` (which now preserves the raw Scryfall values) and into the backfill path only. The Scryfall dataset stores names and set codes as Scryfall provides them.

Update the `run_result` type and the broadcast/log messages to include `persisted`.

- [ ] **Step 6: Run tests to verify they pass**

```bash
mix test test/scry_2/cards/scryfall_test.exs
```

Expected: all pass.

- [ ] **Step 7: Run full test suite**

```bash
mix precommit
```

Expected: zero warnings, all tests pass.

- [ ] **Step 8: Commit**

```bash
jj describe -m "feat: persist Scryfall cards as independent dataset during bulk import"
```

---

### Task 5: Update `parse_card/1` pure tests

**Files:**
- Modify: `test/scry_2/cards/scryfall_test.exs`

The `parse_card/1` tests need updating since the return shape changed from `%{name, set_code, arena_id}` to the full attribute map.

- [ ] **Step 1: Update pure tests**

```elixir
describe "parse_card/1 (pure)" do
  test "extracts all typed fields from a Scryfall card map" do
    result = Scryfall.parse_card(@scryfall_mountain)

    assert result.scryfall_id == "scryfallid-mountain-lci"
    assert result.name == "Mountain"
    assert result.set_code == "lci"
    assert result.arena_id == 91_001
    assert result.type_line == "Basic Land — Mountain"
    assert result.rarity == "common"
    assert result.colors == ""
    assert result.color_identity == "R"
    assert result.raw == @scryfall_mountain
  end

  test "preserves full DFC name (splitting happens in backfill path)" do
    result = Scryfall.parse_card(@scryfall_dfc)

    assert result.name == "Bonecrusher Giant // Stomp"
    assert result.set_code == "otj"
    assert result.arena_id == 91_003
  end

  test "handles nil arena_id (card is still parsed for persistence)" do
    result = Scryfall.parse_card(@scryfall_no_arena)

    assert result.scryfall_id == "scryfallid-paper-only"
    assert result.arena_id == nil
  end

  test "returns nil when scryfall id is missing" do
    assert Scryfall.parse_card(%{"name" => "Test", "set" => "lci"}) == nil
  end

  test "joins color arrays into strings" do
    result = Scryfall.parse_card(@scryfall_bolt)

    assert result.colors == "R"
    assert result.color_identity == "R"
  end
end
```

- [ ] **Step 2: Run tests**

```bash
mix test test/scry_2/cards/scryfall_test.exs
```

Expected: all pass.

- [ ] **Step 3: Commit**

```bash
jj describe -m "test: update parse_card tests for full Scryfall attribute extraction"
```

---

### Task 6: Final verification

- [ ] **Step 1: Run full precommit**

```bash
mix precommit
```

Expected: zero warnings, all tests pass.

- [ ] **Step 2: Manual smoke test**

```elixir
# Via tidewave or remote shell:
Scry2.Cards.Scryfall.run()
# Expected: {:ok, %{matched: ~13k, skipped: ~100k, persisted: ~113k}}

Scry2.Cards.scryfall_count()
# Expected: ~113,000

card = Scry2.Cards.get_scryfall_by_arena_id(91001)
card.name        # "Mountain"
card.image_uris   # %{"normal" => "https://...", ...}
card.raw |> Map.keys() |> length()  # ~60 keys
```

- [ ] **Step 3: Commit**

```bash
jj describe -m "feat: Scryfall independent dataset — persist, query, backfill arena_id"
```
