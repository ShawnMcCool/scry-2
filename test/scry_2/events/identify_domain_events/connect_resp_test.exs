defmodule Scry2.Events.IdentifyDomainEvents.ConnectRespTest do
  @moduledoc """
  Direct tests for the GREMessageType_ConnectResp translator.

  The coordinator (`Scry2.Events.IdentifyDomainEvents`) is exercised end-to-end
  by `IdentifyDomainEventsTest` against real captured GRE batches. These tests
  cover the helper-level branches: deck_id seat suffix, pending prefix when
  match_id is unknown, empty deck/sideboard, and the absence of ConnectResp
  in the message list.
  """
  use ExUnit.Case, async: true

  alias Scry2.Events.Deck.DeckSubmitted
  alias Scry2.Events.IdentifyDomainEvents.ConnectResp

  defp connect_resp_message(deck_cards, sideboard_cards) do
    %{
      "type" => "GREMessageType_ConnectResp",
      "connectResp" => %{
        "deckMessage" => %{
          "deckCards" => deck_cards,
          "sideboardCards" => sideboard_cards
        }
      }
    }
  end

  @occurred_at ~U[2026-05-01 12:00:00Z]

  describe "build/5" do
    test "produces DeckSubmitted with seat-suffixed deck_id when match_id is known" do
      messages = [connect_resp_message([67_810, 67_810, 67_810, 67_810, 91_234], [])]

      assert [%DeckSubmitted{} = event] =
               ConnectResp.build(messages, "match-abc", @occurred_at, 1, %{})

      assert event.mtga_match_id == "match-abc"
      assert event.mtga_deck_id == "match-abc:seat1"
      assert event.self_seat_id == 1
      assert event.occurred_at == @occurred_at
    end

    test "uses pending: prefix when match_id is nil" do
      messages = [connect_resp_message([91_234], [])]

      assert [%DeckSubmitted{} = event] =
               ConnectResp.build(messages, nil, @occurred_at, 2, %{})

      assert event.mtga_match_id == nil
      assert event.mtga_deck_id == "pending:seat2"
      assert event.self_seat_id == 2
    end

    test "aggregates duplicate arena_ids in deckCards into card counts" do
      messages = [connect_resp_message([67_810, 67_810, 67_810, 67_810, 91_234], [12_345])]

      [%DeckSubmitted{} = event] =
        ConnectResp.build(messages, "match-1", @occurred_at, 1, %{})

      card_67810 = Enum.find(event.main_deck, &(&1.arena_id == 67_810))
      assert card_67810.count == 4

      card_91234 = Enum.find(event.main_deck, &(&1.arena_id == 91_234))
      assert card_91234.count == 1

      [sb] = event.sideboard
      assert sb.arena_id == 12_345
      assert sb.count == 1
    end

    test "empty deckMessage produces an empty deck and sideboard" do
      messages = [connect_resp_message([], [])]

      assert [%DeckSubmitted{} = event] =
               ConnectResp.build(messages, "match-1", @occurred_at, 1, %{})

      assert event.main_deck == []
      assert event.sideboard == []
    end

    test "missing deckMessage falls back to empty lists rather than crashing" do
      messages = [%{"type" => "GREMessageType_ConnectResp", "connectResp" => %{}}]

      assert [%DeckSubmitted{} = event] =
               ConnectResp.build(messages, "match-1", @occurred_at, 1, %{})

      assert event.main_deck == []
      assert event.sideboard == []
    end

    test "returns [] when no ConnectResp message is present in the batch" do
      messages = [%{"type" => "GREMessageType_GameStateMessage"}]
      assert [] = ConnectResp.build(messages, "match-1", @occurred_at, 1, %{})
    end

    test "returns [] when message list is empty" do
      assert [] = ConnectResp.build([], "match-1", @occurred_at, 1, %{})
    end
  end
end
