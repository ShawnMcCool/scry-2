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

  describe "infer_limited_format/1" do
    test "returns the granular draft label for draft queues" do
      assert EnrichEvents.infer_limited_format("PickTwoDraft_SOS_20260421") == "Pick Two Draft"
      assert EnrichEvents.infer_limited_format("QuickDraft_SOS_20260430") == "Quick Draft"
      assert EnrichEvents.infer_limited_format("PremierDraft_SOS_20260421") == "Premier Draft"
    end

    test "returns the granular label for sealed" do
      assert EnrichEvents.infer_limited_format("Sealed_SOS_20260421") == "Sealed"
    end

    test "collapses limited Direct Challenge to plain \"Limited\"" do
      assert EnrichEvents.infer_limited_format("DirectGameLimited") == "Limited"
    end

    test "returns nil for constructed and unknown event names" do
      assert EnrichEvents.infer_limited_format("Ladder") == nil
      assert EnrichEvents.infer_limited_format("Traditional_Ladder") == nil
      assert EnrichEvents.infer_limited_format("DirectGame") == nil
      assert EnrichEvents.infer_limited_format(nil) == nil
    end
  end

  describe "enrich/2 — GameCompleted on_play enrichment" do
    test "populates on_play from ingestion state when nil on event" do
      event = build_game_completed(on_play: nil)

      state = %IngestionState{
        match: %Match{on_play_for_current_game: true}
      }

      [enriched] = EnrichEvents.enrich([event], state)

      assert enriched.on_play == true
    end

    test "preserves existing on_play when event is true" do
      event = build_game_completed(on_play: true)

      state = %IngestionState{
        match: %Match{on_play_for_current_game: false}
      }

      [enriched] = EnrichEvents.enrich([event], state)

      assert enriched.on_play == true
    end

    test "on_play stays nil when both event and state are nil" do
      event = build_game_completed(on_play: nil)

      state = %IngestionState{
        match: %Match{on_play_for_current_game: nil}
      }

      [enriched] = EnrichEvents.enrich([event], state)

      assert is_nil(enriched.on_play)
    end
  end
end
