defmodule Scry2.Events.IdentifyDomainEvents.GREProtocolTest do
  use ExUnit.Case, async: true

  alias Scry2.Events.IdentifyDomainEvents.GREProtocol

  describe "game_state_message?/1" do
    test "matches GameStateMessage" do
      assert GREProtocol.game_state_message?(%{"type" => "GREMessageType_GameStateMessage"})
    end

    test "matches QueuedGameStateMessage" do
      assert GREProtocol.game_state_message?(%{"type" => "GREMessageType_QueuedGameStateMessage"})
    end

    test "rejects other GRE messages" do
      refute GREProtocol.game_state_message?(%{"type" => "GREMessageType_ConnectResp"})
      refute GREProtocol.game_state_message?(%{})
      refute GREProtocol.game_state_message?(nil)
    end
  end

  describe "find_gre_message/2" do
    test "returns the first matching message" do
      messages = [
        %{"type" => "GREMessageType_ConnectResp", "id" => 1},
        %{"type" => "GREMessageType_GameStateMessage", "id" => 2},
        %{"type" => "GREMessageType_GameStateMessage", "id" => 3}
      ]

      assert GREProtocol.find_gre_message(messages, "GREMessageType_GameStateMessage") ==
               %{"type" => "GREMessageType_GameStateMessage", "id" => 2}
    end

    test "returns nil when no match" do
      assert GREProtocol.find_gre_message([], "anything") == nil
      assert GREProtocol.find_gre_message([%{"type" => "X"}], "Y") == nil
    end
  end

  describe "extract_game_state/1" do
    test "returns the gameStateMessage payload" do
      msg = %{"type" => "GREMessageType_GameStateMessage", "gameStateMessage" => %{"foo" => 1}}
      assert GREProtocol.extract_game_state(msg) == %{"foo" => 1}
    end

    test "returns nil when key is missing" do
      assert GREProtocol.extract_game_state(%{}) == nil
    end
  end

  describe "resolve_player_seat/1" do
    test "returns the seat from the first single-seat message" do
      messages = [
        %{"systemSeatIds" => [1, 2]},
        %{"systemSeatIds" => [2]},
        %{"systemSeatIds" => [1]}
      ]

      assert GREProtocol.resolve_player_seat(messages) == 2
    end

    test "falls back to 1 when no single-seat message exists" do
      assert GREProtocol.resolve_player_seat([%{"systemSeatIds" => [1, 2]}]) == 1
      assert GREProtocol.resolve_player_seat([]) == 1
    end
  end

  describe "extract_match_id/1" do
    test "returns matchID from the first GameStateMessage with one" do
      messages = [
        %{"type" => "GREMessageType_ConnectResp"},
        %{
          "type" => "GREMessageType_GameStateMessage",
          "gameStateMessage" => %{"gameInfo" => %{"matchID" => "match-abc"}}
        }
      ]

      assert GREProtocol.extract_match_id(messages) == "match-abc"
    end

    test "returns nil when no GameStateMessage carries a matchID" do
      assert GREProtocol.extract_match_id([]) == nil
      assert GREProtocol.extract_match_id([%{"type" => "GREMessageType_ConnectResp"}]) == nil
    end
  end

  describe "zone_name/1" do
    test "maps a positive id to a string" do
      assert GREProtocol.zone_name(7) == "zone_7"
    end

    test "returns nil for nil and non-positive values" do
      assert GREProtocol.zone_name(nil) == nil
      assert GREProtocol.zone_name(0) == nil
      assert GREProtocol.zone_name(-1) == nil
      assert GREProtocol.zone_name("not a zone") == nil
    end
  end

  describe "find_detail_string/2" do
    test "returns the first valueString head for the matching key" do
      details = [
        %{"key" => "name", "valueString" => ["Lightning Bolt", "ignored"]},
        %{"key" => "type", "valueString" => ["Instant"]}
      ]

      assert GREProtocol.find_detail_string(details, "name") == "Lightning Bolt"
      assert GREProtocol.find_detail_string(details, "type") == "Instant"
    end

    test "returns nil when key is missing" do
      assert GREProtocol.find_detail_string([], "name") == nil
      assert GREProtocol.find_detail_string([%{"key" => "name"}], "name") == nil
    end
  end

  describe "find_detail_int/2" do
    test "returns the first valueInt32 head for the matching key" do
      details = [%{"key" => "count", "valueInt32" => [3, 4]}]
      assert GREProtocol.find_detail_int(details, "count") == 3
    end

    test "returns nil when key is missing or shape is wrong" do
      assert GREProtocol.find_detail_int([], "count") == nil
      assert GREProtocol.find_detail_int([%{"key" => "count"}], "count") == nil
    end
  end

  describe "aggregate_card_list/1" do
    test "compresses repeated arena_ids into {arena_id, count} sorted by id" do
      assert GREProtocol.aggregate_card_list([67810, 67810, 67810, 1234, 1234]) == [
               %{arena_id: 1234, count: 2},
               %{arena_id: 67810, count: 3}
             ]
    end

    test "returns empty list for non-list input" do
      assert GREProtocol.aggregate_card_list(nil) == []
      assert GREProtocol.aggregate_card_list(%{}) == []
    end

    test "returns empty list for empty input" do
      assert GREProtocol.aggregate_card_list([]) == []
    end
  end

  describe "cached_objects_to_map/1" do
    test "passes a map through unchanged" do
      assert GREProtocol.cached_objects_to_map(%{"a" => 1}) == %{"a" => 1}
    end

    test "returns an empty map for nil and non-map values" do
      assert GREProtocol.cached_objects_to_map(nil) == %{}
      assert GREProtocol.cached_objects_to_map([]) == %{}
      assert GREProtocol.cached_objects_to_map("string") == %{}
    end
  end
end
