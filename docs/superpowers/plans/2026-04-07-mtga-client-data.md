# MTGA Client Card Database — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import the MTGA client's local card database as the primary card identity source (100% arena_id coverage), and update the image cache to look up Scryfall images by `(set, collector_number)` from this data instead of by `arena_id` from the Scryfall bulk dataset.

**Architecture:** New `Scry2.Cards.MtgaClientData` module reads the MTGA client's `Raw_CardDatabase` SQLite file (located in the MTGA installation), joins card data with English localizations, and upserts into `cards_mtga_cards`. The `ImageCache` is updated to resolve images via `GET /cards/{set}/{collector_number}` on the Scryfall API, using expansion code and collector number from the MTGA card data.

**Tech Stack:** Elixir, Ecto, Exqlite (direct SQLite queries on the MTGA file), Req (Scryfall API)

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `priv/repo/migrations/*_create_cards_mtga_cards.exs` | Create | Table + indexes |
| `lib/scry_2/cards/mtga_card.ex` | Create | Schema for `cards_mtga_cards` |
| `lib/scry_2/cards/mtga_client_data.ex` | Create | Import module — reads MTGA SQLite, upserts cards |
| `lib/scry_2/cards.ex` | Modify | Add MTGA card context functions |
| `lib/scry_2/config.ex` | Modify | Add `:mtga_data_dir` config key |
| `defaults/scry_2.toml` | Modify | Document MTGA data dir |
| `lib/scry_2/cards/image_cache.ex` | Modify | Use MTGA card → Scryfall API for images |
| `test/scry_2/cards/mtga_client_data_test.exs` | Create | Import tests |
| `test/scry_2/cards/image_cache_test.exs` | Modify | Update download tests for new lookup |
| `test/support/factory.ex` | Modify | Add `build_mtga_card`, `create_mtga_card` |

---

### Task 1: Migration + Schema + Config

**Files:**
- Create: `priv/repo/migrations/*_create_cards_mtga_cards.exs`
- Create: `lib/scry_2/cards/mtga_card.ex`
- Modify: `lib/scry_2/config.ex`
- Modify: `defaults/scry_2.toml`

- [ ] **Step 1: Generate migration**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix ecto.gen.migration create_cards_mtga_cards
```

Write migration body:

```elixir
def change do
  create table(:cards_mtga_cards) do
    add :arena_id, :integer, null: false
    add :name, :string, null: false
    add :expansion_code, :string
    add :collector_number, :string
    add :rarity, :integer
    add :colors, :string, default: ""
    add :types, :string, default: ""
    add :is_token, :boolean, default: false
    add :is_digital_only, :boolean, default: false
    add :art_id, :integer
    add :power, :string, default: ""
    add :toughness, :string, default: ""

    timestamps(type: :utc_datetime)
  end

  create unique_index(:cards_mtga_cards, [:arena_id])
  create index(:cards_mtga_cards, [:expansion_code])
  create index(:cards_mtga_cards, [:name])
end
```

- [ ] **Step 2: Run migration**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix ecto.migrate
```

- [ ] **Step 3: Create schema**

Create `lib/scry_2/cards/mtga_card.ex`:

```elixir
defmodule Scry2.Cards.MtgaCard do
  @moduledoc """
  Schema for `cards_mtga_cards` — card identity data imported from
  the MTGA client's local `Raw_CardDatabase` SQLite file.

  This is the **primary card identity source** in Scry2. Every arena_id
  that MTGA assigns has an entry here, including tokens, digital-only
  cards, and promo printings that external sources like Scryfall may not
  catalog.

  The table is disposable and idempotent — re-run
  `Scry2.Cards.MtgaClientData.run()` after any MTGA update to refresh.

  ## Rarity values (MTGA enum)

  0 = token/special, 1 = basic land, 2 = common, 3 = uncommon,
  4 = rare, 5 = mythic rare.

  ## Colors and Types

  Stored as comma-separated integer strings matching MTGA's internal
  enum system (e.g., colors `"1,3"` = White,Black; types `"2"` = Creature).
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "cards_mtga_cards" do
    field :arena_id, :integer
    field :name, :string
    field :expansion_code, :string
    field :collector_number, :string
    field :rarity, :integer
    field :colors, :string, default: ""
    field :types, :string, default: ""
    field :is_token, :boolean, default: false
    field :is_digital_only, :boolean, default: false
    field :art_id, :integer
    field :power, :string, default: ""
    field :toughness, :string, default: ""

    timestamps(type: :utc_datetime)
  end

  def changeset(card, attrs) do
    card
    |> cast(attrs, [
      :arena_id,
      :name,
      :expansion_code,
      :collector_number,
      :rarity,
      :colors,
      :types,
      :is_token,
      :is_digital_only,
      :art_id,
      :power,
      :toughness
    ])
    |> validate_required([:arena_id, :name])
    |> unique_constraint(:arena_id)
  end
end
```

- [ ] **Step 4: Add config keys**

In `lib/scry_2/config.ex`:
- Add `| :mtga_data_dir` to the `@type key` union
- Add to defaults: `mtga_data_dir: nil,` (nil means auto-discover from MTGA installation)
- Add to `merge_toml/2`: `mtga_data_dir: expand(get_in(toml, ["mtga_logs", "data_dir"])) || defaults.mtga_data_dir,`

In `defaults/scry_2.toml`, add under `[mtga_logs]`:

```toml
# Path to MTGA's data directory containing Raw_CardDatabase_*.mtga.
# If unset, Scry2 derives it from the MTGA installation path.
# data_dir = "/home/you/.local/share/Steam/steamapps/common/MTGA/MTGA_Data/Downloads/Raw"
```

- [ ] **Step 5: Verify compilation**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix compile --warnings-as-errors
```

---

### Task 2: Context functions + factory helpers (TDD)

**Files:**
- Modify: `lib/scry_2/cards.ex`
- Modify: `test/scry_2/cards_test.exs`
- Modify: `test/support/factory.ex`

- [ ] **Step 1: Add factory helpers**

In `test/support/factory.ex`, add `MtgaCard` to alias, then:

```elixir
def build_mtga_card(attrs \\ %{}) do
  defaults = %{
    arena_id: :rand.uniform(1_000_000),
    name: "Test MTGA Card",
    expansion_code: "TST",
    collector_number: "1",
    rarity: 2,
    colors: "",
    types: "2",
    is_token: false,
    is_digital_only: false,
    art_id: 12345,
    power: "",
    toughness: ""
  }

  struct(Scry2.Cards.MtgaCard, Map.merge(defaults, Map.new(attrs)))
end

def create_mtga_card(attrs \\ %{}) do
  attrs
  |> build_mtga_card()
  |> Map.from_struct()
  |> Map.drop([:__meta__])
  |> then(&Cards.upsert_mtga_card!/1)
end
```

- [ ] **Step 2: Write failing tests**

In `test/scry_2/cards_test.exs`, add:

```elixir
describe "upsert_mtga_card!/1" do
  test "creates a new MTGA card" do
    card =
      Cards.upsert_mtga_card!(%{
        arena_id: 91_500,
        name: "Test Card",
        expansion_code: "TST",
        collector_number: "42"
      })

    assert card.arena_id == 91_500
    assert card.name == "Test Card"
  end

  test "updates an existing card by arena_id (idempotent)" do
    Cards.upsert_mtga_card!(%{arena_id: 91_501, name: "Old Name"})
    second = Cards.upsert_mtga_card!(%{arena_id: 91_501, name: "New Name"})

    assert second.name == "New Name"
  end
end

describe "get_mtga_card/1" do
  test "returns the card for a given arena_id" do
    TestFactory.create_mtga_card(%{arena_id: 91_600, name: "Found"})
    card = Cards.get_mtga_card(91_600)
    assert card.name == "Found"
  end

  test "returns nil for unknown arena_id" do
    assert Cards.get_mtga_card(99_999_999) == nil
  end
end

describe "mtga_card_count/0" do
  test "returns the count of MTGA cards" do
    TestFactory.create_mtga_card(%{arena_id: 91_700})
    TestFactory.create_mtga_card(%{arena_id: 91_701})
    assert Cards.mtga_card_count() >= 2
  end
end
```

- [ ] **Step 3: Run tests to verify RED**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test test/scry_2/cards_test.exs
```

- [ ] **Step 4: Implement context functions**

In `lib/scry_2/cards.ex`:
- Update moduledoc to include `cards_mtga_cards`
- Add `MtgaCard` to alias: `alias Scry2.Cards.{Card, MtgaCard, ScryfallCard, Set}`
- Add section:

```elixir
# ── MTGA Cards ─────────────────────────────────────────────────────────

@doc "Returns the total MTGA card count."
def mtga_card_count do
  Repo.aggregate(MtgaCard, :count, :id)
end

@doc "Returns the MTGA card for the given arena_id, or nil."
def get_mtga_card(arena_id) when is_integer(arena_id) do
  Repo.get_by(MtgaCard, arena_id: arena_id)
end

@doc """
Upserts an MTGA card by `arena_id`.
"""
def upsert_mtga_card!(attrs) do
  attrs = Map.new(attrs)

  %MtgaCard{}
  |> MtgaCard.changeset(attrs)
  |> Repo.insert!(
    on_conflict: {:replace_all_except, [:id, :inserted_at]},
    conflict_target: [:arena_id]
  )
end
```

- [ ] **Step 5: Run tests to verify GREEN**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test test/scry_2/cards_test.exs
```

---

### Task 3: MtgaClientData import module

**Files:**
- Create: `lib/scry_2/cards/mtga_client_data.ex`
- Create: `test/scry_2/cards/mtga_client_data_test.exs`

- [ ] **Step 1: Write failing test**

Create `test/scry_2/cards/mtga_client_data_test.exs`:

```elixir
defmodule Scry2.Cards.MtgaClientDataTest do
  use Scry2.DataCase, async: true

  alias Scry2.Cards
  alias Scry2.Cards.MtgaClientData

  describe "run/1 with the real MTGA database" do
    @tag :external
    test "imports cards from the MTGA client database" do
      assert {:ok, %{imported: count}} = MtgaClientData.run()
      assert count > 20_000
      assert Cards.mtga_card_count() > 20_000

      # Verify our previously-missing cards are now present.
      gnarlid = Cards.get_mtga_card(93_937)
      assert gnarlid.name == "Gnarlid Colony"
      assert gnarlid.expansion_code == "FDN"
      assert gnarlid.collector_number == "224"

      forest = Cards.get_mtga_card(100_652)
      assert forest.name == "Forest"
      assert forest.expansion_code == "TMT"
    end
  end

  describe "find_database_path/1" do
    test "finds the Raw_CardDatabase file in a directory" do
      # Create a temp dir with a fake database file.
      dir = Path.join(System.tmp_dir!(), "mtga_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      fake_db = Path.join(dir, "Raw_CardDatabase_abc123.mtga")
      File.write!(fake_db, "fake")

      assert MtgaClientData.find_database_path(dir) == fake_db

      File.rm_rf!(dir)
    end

    test "returns nil when no database file exists" do
      dir = Path.join(System.tmp_dir!(), "empty_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      assert MtgaClientData.find_database_path(dir) == nil
      File.rm_rf!(dir)
    end
  end
end
```

Note: The `@tag :external` test hits the real MTGA database file on disk. Exclude from normal `mix test` runs. Run explicitly with `mix test --include external`.

- [ ] **Step 2: Run tests to verify RED**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test test/scry_2/cards/mtga_client_data_test.exs --exclude external
```

Expected: `find_database_path` tests fail (module undefined).

- [ ] **Step 3: Implement MtgaClientData**

Create `lib/scry_2/cards/mtga_client_data.ex`:

```elixir
defmodule Scry2.Cards.MtgaClientData do
  @moduledoc """
  Imports card identity data from the MTGA client's local
  `Raw_CardDatabase` SQLite file.

  The MTGA client stores a complete card database as a SQLite file at
  `MTGA_Data/Downloads/Raw/Raw_CardDatabase_*.mtga`. This module reads
  it directly and upserts every card into `cards_mtga_cards`.

  ## Usage

      MtgaClientData.run()
      # => {:ok, %{imported: 24413}}

  Safe to re-run after MTGA updates — upserts by `arena_id`.

  ## Auto-discovery

  The database filename includes a content hash that changes with MTGA
  updates (e.g., `Raw_CardDatabase_3496a613c4c9f4416ca8d7aa5b8bd47a.mtga`).
  `find_database_path/1` scans the Raw directory for the current file.
  """

  alias Scry2.Cards
  alias Scry2.Config

  require Scry2.Log, as: Log

  @default_raw_dir "/home/shawn/.local/share/Steam/steamapps/common/MTGA/MTGA_Data/Downloads/Raw"

  @type run_result :: {:ok, %{imported: non_neg_integer()}} | {:error, term()}

  @doc """
  Imports all cards from the MTGA client database.

  Options:
    * `:database_path` — override the path to the Raw_CardDatabase file
  """
  @spec run(keyword()) :: run_result()
  def run(opts \\ []) do
    db_path =
      Keyword.get_lazy(opts, :database_path, fn ->
        data_dir = Config.get(:mtga_data_dir) || @default_raw_dir
        find_database_path(data_dir)
      end)

    case db_path do
      nil ->
        {:error, :database_not_found}

      path ->
        import_from(path)
    end
  end

  @doc """
  Finds the `Raw_CardDatabase_*.mtga` file in the given directory.
  Returns the full path, or nil if not found.
  """
  @spec find_database_path(String.t()) :: String.t() | nil
  def find_database_path(dir) do
    case Path.wildcard(Path.join(dir, "Raw_CardDatabase_*.mtga")) do
      [path | _] -> path
      [] -> nil
    end
  end

  defp import_from(db_path) do
    {:ok, conn} = Exqlite.Sqlite3.open(db_path, [:readonly])

    try do
      {:ok, statement} =
        Exqlite.Sqlite3.prepare(conn, """
        SELECT
          c.GrpId,
          l.Loc,
          c.ExpansionCode,
          c.CollectorNumber,
          c.Rarity,
          c.Colors,
          c.Types,
          c.IsToken,
          c.IsDigitalOnly,
          c.ArtId,
          c.Power,
          c.Toughness
        FROM Cards c
        LEFT JOIN Localizations_enUS l
          ON c.TitleId = l.LocId AND l.Formatted = 1
        """)

      count = import_rows(conn, statement, 0)

      Log.info(:importer, "MTGA client data: imported #{count} cards")
      {:ok, %{imported: count}}
    after
      Exqlite.Sqlite3.close(conn)
    end
  end

  defp import_rows(conn, statement, count) do
    case Exqlite.Sqlite3.step(conn, statement) do
      {:row, row} ->
        row_to_attrs(row) |> Cards.upsert_mtga_card!()
        import_rows(conn, statement, count + 1)

      :done ->
        count
    end
  end

  defp row_to_attrs([
         arena_id,
         name,
         expansion_code,
         collector_number,
         rarity,
         colors,
         types,
         is_token,
         is_digital_only,
         art_id,
         power,
         toughness
       ]) do
    %{
      arena_id: arena_id,
      name: name || "Unknown (#{arena_id})",
      expansion_code: expansion_code || "",
      collector_number: collector_number || "",
      rarity: rarity,
      colors: colors || "",
      types: types || "",
      is_token: is_token == 1,
      is_digital_only: is_digital_only == 1,
      art_id: art_id,
      power: power || "",
      toughness: toughness || ""
    }
  end
end
```

- [ ] **Step 4: Run tests to verify GREEN**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test test/scry_2/cards/mtga_client_data_test.exs --exclude external
```

- [ ] **Step 5: Run the external integration test**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test test/scry_2/cards/mtga_client_data_test.exs --include external
```

Expected: imports ~24k cards, Gnarlid Colony and Forest found.

---

### Task 4: Update ImageCache to use MTGA card data

**Files:**
- Modify: `lib/scry_2/cards/image_cache.ex`
- Modify: `test/scry_2/cards/image_cache_test.exs`

- [ ] **Step 1: Update test fixtures**

In `test/scry_2/cards/image_cache_test.exs`, change the setup and tests that create `ScryfallCard` records to create `MtgaCard` records instead. The download test needs to stub the Scryfall API card lookup (which returns JSON with `image_uris`) rather than a direct image URL.

Replace the existing download test:

```elixir
test "downloads missing images from Scryfall via set+collector lookup", %{cache_dir: cache_dir} do
  # Seed an MTGA card (instead of ScryfallCard).
  TestFactory.create_mtga_card(%{
    arena_id: 91_002,
    name: "Test Card",
    expansion_code: "TST",
    collector_number: "42"
  })

  # Stub: Scryfall /cards/tst/42 returns JSON with image_uris,
  # then the image URL returns binary data.
  Req.Test.stub(ImageCache, fn conn ->
    case conn.request_path do
      "/cards/tst/42" ->
        Req.Test.json(conn, %{
          "image_uris" => %{"normal" => "http://stub.test/image.jpg"}
        })

      "/image.jpg" ->
        Plug.Conn.resp(conn, 200, "fake jpeg data")
    end
  end)

  assert {:ok, %{cached: 0, downloaded: 1, failed: 0}} =
           ImageCache.ensure_cached([91_002],
             cache_dir: cache_dir,
             req_options: [plug: {Req.Test, ImageCache}]
           )

  assert File.exists?(Path.join(cache_dir, "91002.jpg"))
end
```

Update the "skips arena_ids with no record" test to use `MtgaCard`:

```elixir
test "skips arena_ids with no MtgaCard record", %{cache_dir: cache_dir} do
  assert {:ok, %{cached: 0, downloaded: 0, failed: 1}} =
           ImageCache.ensure_cached([99_999_999], cache_dir: cache_dir)
end
```

Update the "skips cards with no image_uris" test — now it becomes "skips cards with no expansion_code":

```elixir
test "skips cards with no expansion code", %{cache_dir: cache_dir} do
  TestFactory.create_mtga_card(%{
    arena_id: 91_003,
    name: "No Set",
    expansion_code: "",
    collector_number: ""
  })

  assert {:ok, %{cached: 0, downloaded: 0, failed: 1}} =
           ImageCache.ensure_cached([91_003], cache_dir: cache_dir)
end
```

Update the mixed test similarly.

- [ ] **Step 2: Run tests to verify RED**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test test/scry_2/cards/image_cache_test.exs
```

- [ ] **Step 3: Update `download_image/3` in ImageCache**

Replace the existing `download_image/3` function:

```elixir
defp download_image(arena_id, path, req_options) do
  case Cards.get_mtga_card(arena_id) do
    nil ->
      :error

    %{expansion_code: code, collector_number: num}
    when code in [nil, ""] or num in [nil, ""] ->
      :error

    %{expansion_code: code, collector_number: num} ->
      case fetch_scryfall_image_url(code, num, req_options) do
        {:ok, url} -> fetch_and_save(url, path, req_options)
        :error -> :error
      end
  end
end

defp fetch_scryfall_image_url(set_code, collector_number, req_options) do
  url = "https://api.scryfall.com/cards/#{String.downcase(set_code)}/#{collector_number}"

  options =
    Keyword.merge(
      [url: url, receive_timeout: 10_000, headers: @scryfall_headers],
      req_options
    )

  case Req.get(options) do
    {:ok, %Req.Response{status: 200, body: %{"image_uris" => %{"normal" => image_url}}}} ->
      {:ok, image_url}

    {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
      # DFC cards: try card_faces[0].image_uris
      case get_in(body, ["card_faces", Access.at(0), "image_uris", "normal"]) do
        nil -> :error
        url -> {:ok, url}
      end

    _ ->
      :error
  end
end
```

Also update the `@scryfall_headers` accept header to include both:

```elixir
@scryfall_headers [
  {"user-agent", "Scry2/0.1.0 (personal project; no bulk scraping)"},
  {"accept", "application/json, image/*"}
]
```

- [ ] **Step 4: Run tests to verify GREEN**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test test/scry_2/cards/image_cache_test.exs
```

- [ ] **Step 5: Run full test suite**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix precommit
```

---

### Task 5: Final verification

- [ ] **Step 1: Import MTGA cards via tidewave**

```elixir
Scry2.Cards.MtgaClientData.run()
# Expected: {:ok, %{imported: ~24400}}
```

- [ ] **Step 2: Clear image cache and re-test the previously-missing cards**

```elixir
# Delete cached images for the two formerly-missing cards
dir = Scry2.Config.get(:image_cache_dir)
File.rm(Path.join(dir, "93937.jpg"))
File.rm(Path.join(dir, "100652.jpg"))

# Re-cache them — should now succeed via set+collector_number lookup
Scry2.Cards.ImageCache.ensure_cached([93937, 100652])
# Expected: {:ok, %{cached: 0, downloaded: 2, failed: 0}}
```

- [ ] **Step 3: Open http://localhost:4002/mulligans — verify all cards show images, no placeholders**

- [ ] **Step 4: Run precommit**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix precommit
```
