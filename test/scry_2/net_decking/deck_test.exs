defmodule Scry2.NetDecking.DeckTest do
  use Scry2.DataCase, async: true

  alias Scry2.NetDecking.Deck
  alias Scry2.Repo

  test "valid changeset persists a deck with json card maps" do
    attrs = %{
      name: "Mono-Red Aggro",
      archetype: "Aggro",
      format: "Standard",
      main_deck: %{"cards" => [%{"arena_id" => 30_001, "count" => 4}]},
      sideboard: %{"cards" => []},
      composition_hash: 12_345,
      source_name: "manual",
      source_url: nil,
      fetched_at: DateTime.utc_now(),
      unresolved_cards: %{"cards" => []}
    }

    assert {:ok, deck} = attrs |> Deck.changeset() |> Repo.insert()
    assert deck.name == "Mono-Red Aggro"
    assert deck.main_deck["cards"] == [%{"arena_id" => 30_001, "count" => 4}]
  end

  test "changeset is invalid when required fields are absent" do
    changeset = Deck.changeset(%{})
    refute changeset.valid?
    errors = errors_on(changeset)
    assert errors[:name]
    assert errors[:main_deck]
    assert errors[:sideboard]
    assert errors[:source_name]
    assert errors[:fetched_at]
  end
end
