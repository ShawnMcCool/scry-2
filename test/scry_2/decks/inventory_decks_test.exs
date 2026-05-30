defmodule Scry2.Decks.InventoryDecksTest do
  use Scry2.DataCase, async: true

  import Scry2.TestFactory

  alias Scry2.Decks

  describe "upsert_inventory_deck!/1" do
    test "inserts a new stub row with name and format (atom keys)" do
      Decks.upsert_inventory_deck!(%{
        deck_id: "inv-1",
        name: "Forest's Might",
        format: "Explorer"
      })

      deck = Decks.get_deck("inv-1")
      assert deck.current_name == "Forest's Might"
      assert deck.format == "Explorer"
      # Stub: no card list, no composition hash, no play data.
      assert deck.current_main_deck == %{}
      assert deck.composition_hash == nil
      assert deck.last_played_at == nil
    end

    test "inserts a new stub row from string keys (replay/backfill shape)" do
      Decks.upsert_inventory_deck!(%{
        "deck_id" => "inv-2",
        "name" => "Dragon's Fire",
        "format" => "Explorer"
      })

      deck = Decks.get_deck("inv-2")
      assert deck.current_name == "Dragon's Fire"
      assert deck.format == "Explorer"
    end

    test "never clobbers an existing deck's card list, stats, format, or starred flag" do
      existing =
        create_deck(
          mtga_deck_id: "inv-3",
          current_name: "Built Deck",
          current_main_deck: %{"cards" => [%{"arena_id" => 91_234, "count" => 4}]},
          format: "Historic"
        )

      Decks.update_deck_flags!(existing, %{starred: true})

      # Inventory snapshot carries a new name and a nil format.
      Decks.upsert_inventory_deck!(%{"deck_id" => "inv-3", "name" => "Renamed", "format" => nil})

      deck = Decks.get_deck("inv-3")
      assert deck.current_name == "Renamed"
      assert deck.format == "Historic"
      assert deck.current_main_deck == %{"cards" => [%{"arena_id" => 91_234, "count" => 4}]}
      assert deck.starred == true
    end

    test "returns :ok and writes nothing when the entry has no deck id" do
      assert Decks.upsert_inventory_deck!(%{"name" => "No Id", "format" => "Standard"}) == :ok
      assert Repo.aggregate(Scry2.Decks.Deck, :count) == 0
    end
  end
end
