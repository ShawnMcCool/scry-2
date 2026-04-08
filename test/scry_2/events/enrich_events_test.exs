defmodule Scry2.Events.EnrichEventsTest do
  use ExUnit.Case, async: true

  import Scry2.TestFactory

  alias Scry2.Events.EnrichEvents
  alias Scry2.Events.IngestionState
  alias Scry2.Events.IngestionState.Match

  defp state_with_game_number(game_number) do
    %IngestionState{match: %Match{current_game_number: game_number}}
  end

  describe "enrich/2 — DeckSubmitted game_number" do
    test "populates game_number from ingestion state when nil on event" do
      event = build_deck_submitted(game_number: nil, main_deck: [])
      state = state_with_game_number(1)

      [enriched] = EnrichEvents.enrich([event], state)

      assert enriched.game_number == 1
    end

    test "preserves existing game_number on event (no override)" do
      event = build_deck_submitted(game_number: 2, main_deck: [])
      state = state_with_game_number(3)

      [enriched] = EnrichEvents.enrich([event], state)

      assert enriched.game_number == 2
    end

    test "deck_colors still populated alongside game_number" do
      event = build_deck_submitted(game_number: nil, main_deck: [], deck_colors: nil)
      state = state_with_game_number(1)

      [enriched] = EnrichEvents.enrich([event], state)

      assert enriched.game_number == 1
      assert enriched.deck_colors == ""
    end
  end

  describe "enrich/2 — DeckSubmitted with nil state game_number" do
    test "game_number stays nil when state has no current_game_number" do
      event = build_deck_submitted(game_number: nil, main_deck: [])
      state = state_with_game_number(nil)

      [enriched] = EnrichEvents.enrich([event], state)

      assert is_nil(enriched.game_number)
    end
  end
end
