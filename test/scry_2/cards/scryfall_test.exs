defmodule Scry2.Cards.ScryfallTest do
  use Scry2.DataCase, async: true

  alias Scry2.Cards
  alias Scry2.Cards.Scryfall
  alias Scry2.TestFactory

  # A realistic Scryfall bulk-data card object with the fields we care about.
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

  # Double-faced card — Scryfall uses "Front // Back" naming.
  @scryfall_dfc %{
    "id" => "scryfallid-bonecrusher-otj",
    "oracle_id" => "oracleid-bonecrusher",
    "name" => "Bonecrusher Giant // Stomp",
    "set" => "otj",
    "arena_id" => 91_003,
    "collector_number" => "115",
    "type_line" => "Creature — Giant // Instant",
    "oracle_text" =>
      "Whenever Bonecrusher Giant becomes the target of a spell, that spell deals 2 damage to its controller.",
    "mana_cost" => "{2}{R}",
    "cmc" => 3.0,
    "colors" => ["R"],
    "color_identity" => ["R"],
    "rarity" => "rare",
    "layout" => "adventure",
    "image_uris" => %{"normal" => "https://example.com/bonecrusher.jpg"}
  }

  @scryfall_no_arena %{
    "id" => "scryfallid-paperonly-lci",
    "oracle_id" => "oracleid-paperonly",
    "name" => "Paper Only Card",
    "set" => "lci",
    "arena_id" => nil,
    "collector_number" => "999",
    "type_line" => "Creature — Human",
    "oracle_text" => "This card is paper only.",
    "mana_cost" => "{1}{W}",
    "cmc" => 2.0,
    "colors" => ["W"],
    "color_identity" => ["W"],
    "rarity" => "uncommon",
    "layout" => "normal",
    "image_uris" => %{"normal" => "https://example.com/paperonly.jpg"}
  }

  describe "parse_card/1 (pure)" do
    test "extracts all typed fields from a Scryfall card" do
      result = Scryfall.parse_card(@scryfall_mountain)

      assert result.name == "Mountain"
      assert result.set_code == "lci"
      assert result.arena_id == 91_001
      assert result.scryfall_id == "scryfallid-mountain-lci"
      assert result.oracle_id == "oracleid-mountain"
      assert result.type_line == "Basic Land — Mountain"
      assert result.rarity == "common"
      assert result.layout == "normal"
      assert result.colors == ""
      assert result.color_identity == "R"
      assert result.cmc == 0.0
      assert result.raw == @scryfall_mountain
    end

    test "preserves DFC name as-is (splitting happens in backfill path only)" do
      result = Scryfall.parse_card(@scryfall_dfc)

      assert result.name == "Bonecrusher Giant // Stomp"
      assert result.set_code == "otj"
      assert result.arena_id == 91_003
    end

    test "parses cards with nil arena_id (no longer returns nil)" do
      result = Scryfall.parse_card(@scryfall_no_arena)

      assert result.name == "Paper Only Card"
      assert result.arena_id == nil
      assert result.scryfall_id == "scryfallid-paperonly-lci"
    end

    test "returns nil when id is missing" do
      assert Scryfall.parse_card(%{"name" => "Test", "set" => "lci"}) == nil
    end

    test "returns nil when set is missing" do
      assert Scryfall.parse_card(%{"id" => "abc", "name" => "Test"}) == nil
    end

    test "returns nil when name is missing" do
      assert Scryfall.parse_card(%{"id" => "abc", "set" => "lci"}) == nil
    end
  end

  describe "run/1 with Req.Test stubs" do
    setup do
      # Seed 17lands cards that the Scryfall backfill should match against.
      set = TestFactory.create_set(%{code: "LCI", name: "Lost Caverns"})

      mountain =
        TestFactory.create_card(%{
          lands17_id: 1,
          name: "Mountain",
          set_id: set.id,
          arena_id: nil
        })

      bolt =
        TestFactory.create_card(%{
          lands17_id: 2,
          name: "Lightning Bolt",
          set_id: set.id,
          arena_id: nil
        })

      bulk_json =
        Jason.encode!([@scryfall_mountain, @scryfall_bolt, @scryfall_dfc, @scryfall_no_arena])

      catalog_json =
        Jason.encode!(%{"download_uri" => "http://stub.test/bulk.json"})

      # Stub: catalog endpoint returns the download URI,
      # bulk endpoint returns the card array.
      Req.Test.stub(Scryfall, fn conn ->
        case conn.request_path do
          "/catalog" ->
            Req.Test.json(conn, Jason.decode!(catalog_json))

          "/bulk.json" ->
            Req.Test.json(conn, Jason.decode!(bulk_json))
        end
      end)

      %{mountain: mountain, bolt: bolt, set: set}
    end

    test "backfills arena_id on matched cards", %{mountain: mountain, bolt: bolt} do
      assert {:ok, %{matched: 2, skipped: 2, persisted: 4}} =
               Scryfall.run(
                 url: "http://stub.test/catalog",
                 req_options: [plug: {Req.Test, Scryfall}]
               )

      assert Cards.get_by_lands17_id(mountain.lands17_id).arena_id == 91_001
      assert Cards.get_by_lands17_id(bolt.lands17_id).arena_id == 91_002
    end

    test "skips cards that have no matching 17lands row" do
      assert {:ok, %{skipped: skipped}} =
               Scryfall.run(
                 url: "http://stub.test/catalog",
                 req_options: [plug: {Req.Test, Scryfall}]
               )

      # @scryfall_no_arena and @scryfall_dfc (otj set not in 17lands) have no match → skipped
      assert skipped >= 1
    end

    test "never overwrites existing arena_id (ADR-014)", %{mountain: mountain} do
      # Pre-set arena_id on mountain
      {:ok, _} = Cards.backfill_arena_id!(mountain, 55_555)

      assert {:ok, _} =
               Scryfall.run(
                 url: "http://stub.test/catalog",
                 req_options: [plug: {Req.Test, Scryfall}]
               )

      # Mountain's arena_id should still be 55_555, not 91_001
      assert Cards.get_by_lands17_id(mountain.lands17_id).arena_id == 55_555
    end

    test "broadcasts arena_ids_backfilled on cards:updates" do
      Scry2.Topics.subscribe(Scry2.Topics.cards_updates())

      {:ok, _} =
        Scryfall.run(
          url: "http://stub.test/catalog",
          req_options: [plug: {Req.Test, Scryfall}]
        )

      assert_receive {:arena_ids_backfilled, _count}
    end

    test "persists all Scryfall cards (including those without arena_id)" do
      Scryfall.run(
        url: "http://stub.test/catalog",
        req_options: [plug: {Req.Test, Scryfall}]
      )

      # All 4 cards in the stub should be persisted
      assert Cards.scryfall_count() == 4

      mountain = Cards.get_scryfall_by_arena_id(91_001)
      assert mountain.name == "Mountain"
      assert mountain.set_code == "LCI"
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

    test "is idempotent — re-running produces same state" do
      opts = [
        url: "http://stub.test/catalog",
        req_options: [plug: {Req.Test, Scryfall}]
      ]

      {:ok, first} = Scryfall.run(opts)
      {:ok, second} = Scryfall.run(opts)

      # First run matches 2, second run matches 0 (already backfilled)
      assert first.matched == 2
      assert second.matched == 0
      # Both runs persist all 4 cards (upserts)
      assert first.persisted == 4
      assert second.persisted == 4
    end
  end

  describe "run/1 error handling" do
    test "returns error when no url configured" do
      assert {:error, :no_url_configured} = Scryfall.run(url: nil, req_options: [])
    end

    test "returns error on non-200 catalog response" do
      Req.Test.stub(Scryfall, fn conn ->
        conn |> Plug.Conn.resp(500, "boom")
      end)

      assert {:error, {:http_status, 500}} =
               Scryfall.run(
                 url: "http://stub.test/catalog",
                 req_options: [plug: {Req.Test, Scryfall}, retry: false]
               )
    end
  end
end
