defmodule Scry2.Events.IdentifyDomainEventsTest do
  use ExUnit.Case, async: true

  alias Scry2.Events.{
    DeckSubmitted,
    DieRollCompleted,
    DraftPickMade,
    DraftStarted,
    GameCompleted,
    IdentifyDomainEvents,
    MatchCompleted,
    MatchCreated,
    RankSnapshot,
    SessionStarted,
    TranslationWarning
  }

  alias Scry2.MtgaLogIngestion.{Event, ExtractEventsFromLog, EventRecord}

  # The self_user_id baked into the captured fixtures.
  @self_user_id "D0FECB2AF1E7FE24"

  # Reads a real fixture and returns a synthetic %EventRecord{} with the
  # fixture's raw JSON and parsed timestamp. Pure setup — no DB.
  defp record_from_fixture(fixture_name) do
    path = Path.join([__DIR__, "..", "..", "fixtures", "mtga_logs", fixture_name])
    chunk = File.read!(path)
    {[%Event{} = event], _warnings} = ExtractEventsFromLog.parse_chunk(chunk, "Player.log", 0)

    %EventRecord{
      id: 1,
      event_type: event.type,
      mtga_timestamp: event.mtga_timestamp,
      file_offset: 0,
      source_file: "Player.log",
      raw_json: event.raw_json,
      processed: false
    }
  end

  describe "translate/2 — MatchGameRoomStateChangedEvent, stateType=Playing" do
    test "produces a single %MatchCreated{} with the expected fields" do
      record = record_from_fixture("match_game_room_state_changed_playing.log")

      assert {[%MatchCreated{} = event], []} =
               IdentifyDomainEvents.translate(record, @self_user_id)

      assert event.mtga_match_id == "008b1926-09a8-40b4-872d-fa987588740c"
      assert event.event_name == "Traditional_Ladder"
      assert event.opponent_screen_name == "Opponent1"
      assert event.opponent_user_id == "OPPONENT_USER_ID_1"
      assert event.platform == "SteamWindows"
      assert event.opponent_platform == "Windows"
      assert event.occurred_at == ~U[2026-04-05 19:18:40Z]
    end

    test "falls back to systemSeatId != 1 for opponent when self_user_id is nil" do
      record = record_from_fixture("match_game_room_state_changed_playing.log")

      assert {[%MatchCreated{} = event], []} = IdentifyDomainEvents.translate(record, nil)
      assert event.opponent_screen_name == "Opponent1"
      assert event.event_name == "Traditional_Ladder"
    end
  end

  describe "translate/2 — MatchGameRoomStateChangedEvent, stateType=MatchCompleted" do
    test "produces a single %MatchCompleted{} with win/loss and game count" do
      record = record_from_fixture("match_game_room_state_changed_completed.log")

      assert {[%MatchCompleted{} = event], []} =
               IdentifyDomainEvents.translate(record, @self_user_id)

      assert event.mtga_match_id == "008b1926-09a8-40b4-872d-fa987588740c"
      assert event.occurred_at == ~U[2026-04-05 19:53:36Z]

      # In the fixture, MatchScope_Match has winningTeamId=1 and the
      # self-user is on teamId=1 (from reservedPlayers[]), so won=true.
      assert event.won == true

      # The fixture's resultList has 3 MatchScope_Game rows.
      assert event.num_games == 3
      assert event.reason == "MatchCompletedReasonType_Success"

      # Per-game results breakdown from MatchScope_Game rows.
      assert length(event.game_results) == 3

      assert Enum.at(event.game_results, 0) == %{
               game_number: 1,
               winning_team_id: 2,
               reason: "ResultReason_Concede"
             }

      assert Enum.at(event.game_results, 1) == %{
               game_number: 2,
               winning_team_id: 1,
               reason: "ResultReason_Concede"
             }

      assert Enum.at(event.game_results, 2) == %{
               game_number: 3,
               winning_team_id: 1,
               reason: "ResultReason_Concede"
             }
    end
  end

  describe "translate/2 — GreToClientEvent, ConnectResp batch" do
    test "produces DeckSubmitted + DieRollCompleted from the ConnectResp fixture" do
      record = record_from_fixture("gre_to_client_event_connect_resp.log")

      {events, []} = IdentifyDomainEvents.translate(record, @self_user_id)

      deck_event = Enum.find(events, &match?(%DeckSubmitted{}, &1))
      die_event = Enum.find(events, &match?(%DieRollCompleted{}, &1))

      assert deck_event != nil
      assert die_event != nil
      assert deck_event.mtga_match_id == "008b1926-09a8-40b4-872d-fa987588740c"
      assert deck_event.mtga_deck_id == "008b1926-09a8-40b4-872d-fa987588740c:seat1"
      assert deck_event.occurred_at == ~U[2026-04-05 19:18:40Z]

      # The fixture's deckCards has 60 entries (a 60-card deck).
      total_main = Enum.reduce(deck_event.main_deck, 0, fn card, acc -> acc + card.count end)
      assert total_main == 60

      # Verify aggregation: arena_id 67810 appears 4 times in the flat array.
      card_67810 = Enum.find(deck_event.main_deck, &(&1.arena_id == 67810))
      assert card_67810.count == 4

      # Sideboard has 15 entries in the fixture.
      total_sb = Enum.reduce(deck_event.sideboard, 0, fn card, acc -> acc + card.count end)
      assert total_sb == 15

      # DieRoll: fixture has seat 1 rolled 19, seat 2 rolled 6
      assert die_event.mtga_match_id == "008b1926-09a8-40b4-872d-fa987588740c"
      assert die_event.self_roll == 19
      assert die_event.opponent_roll == 6
      assert die_event.self_goes_first == true
    end

    test "returns [] when GreToClientEvent has no ConnectResp" do
      record = %EventRecord{
        id: 1,
        event_type: "GreToClientEvent",
        mtga_timestamp: ~U[2026-04-05 19:18:40Z],
        file_offset: 0,
        source_file: "Player.log",
        raw_json:
          Jason.encode!(%{
            "greToClientEvent" => %{
              "greToClientMessages" => [
                %{"type" => "GREMessageType_DieRollResultsResp", "systemSeatIds" => [1, 2]}
              ]
            }
          }),
        processed: false
      }

      assert {[], []} = IdentifyDomainEvents.translate(record, nil)
    end
  end

  describe "translate/2 — fall-through" do
    test "returns {[], []} for an unrelated raw event type" do
      record = %EventRecord{
        id: 1,
        event_type: "GraphGetGraphState",
        file_offset: 0,
        source_file: "Player.log",
        raw_json: ~s({"foo":"bar"}),
        processed: false
      }

      assert {[], []} = IdentifyDomainEvents.translate(record, @self_user_id)
    end

    test "returns {[], []} for MatchGameRoomStateChangedEvent with unknown stateType" do
      record = %EventRecord{
        id: 1,
        event_type: "MatchGameRoomStateChangedEvent",
        file_offset: 0,
        source_file: "Player.log",
        raw_json:
          ~s({"matchGameRoomStateChangedEvent":{"gameRoomInfo":{"gameRoomConfig":{"matchId":"x","reservedPlayers":[]},"stateType":"MatchGameRoomStateType_Closed"}}}),
        processed: false
      }

      assert {[], []} = IdentifyDomainEvents.translate(record, @self_user_id)
    end

    test "emits warning on malformed JSON for a handled type" do
      record = %EventRecord{
        id: 1,
        event_type: "MatchGameRoomStateChangedEvent",
        file_offset: 0,
        source_file: "Player.log",
        raw_json: "not json",
        processed: false
      }

      assert {[], [%TranslationWarning{category: :payload_extraction_failed}]} =
               IdentifyDomainEvents.translate(record, @self_user_id)
    end
  end

  describe "translate/2 — GreToClientEvent, GameStateMessage → GameCompleted" do
    test "produces a %GameCompleted{} from a game-complete fixture" do
      record = record_from_fixture("gre_to_client_event_game_complete.log")

      {events, []} = IdentifyDomainEvents.translate(record, @self_user_id)

      game_event = Enum.find(events, &match?(%GameCompleted{}, &1))
      assert game_event != nil
      assert game_event.mtga_match_id == "55d092c5-fd8a-4af9-b295-cc0003454b2e"
      assert game_event.game_number == 1
      assert game_event.won == true
      assert game_event.num_turns == 6
      assert game_event.self_life_total == 3
      assert game_event.opponent_life_total == 20
      assert game_event.win_reason == "ResultReason_Concede"
      assert game_event.super_format == "SuperFormat_Constructed"
      assert game_event.occurred_at == ~U[2026-04-05 23:24:05Z]
    end
  end

  describe "translate/2 — BotDraftDraftStatus → DraftStarted" do
    test "produces a %DraftStarted{} from the draft status fixture" do
      record = record_from_fixture("bot_draft_draft_status.log")

      assert {[%DraftStarted{} = event], []} = IdentifyDomainEvents.translate(record, nil)
      assert event.mtga_draft_id == "QuickDraft_FDN_20260323"
      assert event.event_name == "QuickDraft_FDN_20260323"
      assert event.set_code == "FDN"
    end
  end

  describe "translate/2 — BotDraftDraftPick → DraftPickMade" do
    test "produces a %DraftPickMade{} from the draft pick fixture" do
      record = record_from_fixture("bot_draft_draft_pick.log")

      assert {[%DraftPickMade{} = event], []} = IdentifyDomainEvents.translate(record, nil)
      assert event.mtga_draft_id == "QuickDraft_FDN_20260323"
      assert event.pack_number == 1
      assert event.pick_number == 1
      assert event.picked_arena_id == 93959
    end
  end

  describe "translate/2 — AuthenticateResponse → SessionStarted" do
    test "produces a %SessionStarted{} with client_id from the fixture" do
      record = record_from_fixture("authenticate_response.log")

      assert {[%SessionStarted{} = event], []} = IdentifyDomainEvents.translate(record, nil)
      assert event.client_id == "D0FECB2AF1E7FE24"
      assert event.screen_name == "Shawn McCool"
      assert event.session_id != nil
    end

    test "emits warning for AuthenticateResponse with missing authenticateResponse key" do
      record = %EventRecord{
        id: 1,
        event_type: "AuthenticateResponse",
        mtga_timestamp: ~U[2026-04-05 23:17:00Z],
        file_offset: 0,
        source_file: "Player.log",
        raw_json: ~s({"other":"data"}),
        processed: false
      }

      assert {[], [%TranslationWarning{category: :payload_extraction_failed}]} =
               IdentifyDomainEvents.translate(record, nil)
    end
  end

  describe "translate/2 — Rank events → RankSnapshot" do
    test "produces a %RankSnapshot{} from a response event" do
      record = %EventRecord{
        id: 1,
        event_type: "RankGetSeasonAndRankDetails",
        mtga_timestamp: ~U[2026-04-05 20:00:00Z],
        file_offset: 0,
        source_file: "Player.log",
        raw_json:
          Jason.encode!(%{
            "constructedSeasonOrdinal" => 88,
            "constructedClass" => "Diamond",
            "constructedLevel" => 4,
            "constructedStep" => 2,
            "constructedMatchesWon" => 28,
            "constructedMatchesLost" => 17,
            "limitedSeasonOrdinal" => 88,
            "limitedClass" => "Silver",
            "limitedLevel" => 1
          }),
        processed: false
      }

      assert {[%RankSnapshot{} = event], []} = IdentifyDomainEvents.translate(record, nil)
      assert event.constructed_class == "Diamond"
      assert event.constructed_level == 4
      assert event.constructed_step == 2
      assert event.constructed_matches_won == 28
      assert event.limited_class == "Silver"
      assert event.season_ordinal == 88
    end

    test "skips request events (those with a 'request' key)" do
      record = %EventRecord{
        id: 1,
        event_type: "RankGetSeasonAndRankDetails",
        file_offset: 0,
        source_file: "Player.log",
        raw_json: ~s({"id":"uuid","request":"{}"}),
        processed: false
      }

      assert {[], []} = IdentifyDomainEvents.translate(record, nil)
    end

    test "produces a %RankSnapshot{} from RankGetCombinedRankInfo response (parsed from <== three-line format)" do
      record = record_from_fixture("rank_get_combined_rank_info_response.log")

      assert {[%RankSnapshot{} = event], []} = IdentifyDomainEvents.translate(record, nil)
      assert event.constructed_class == "Diamond"
      assert event.constructed_level == 4
      assert event.constructed_step == 2
      assert event.constructed_matches_won == 30
      assert event.constructed_matches_lost == 18
      assert event.limited_class == "Silver"
      assert event.occurred_at == ~U[2026-04-06 18:47:51Z]
    end
  end

  describe "event discovery registry (ADR-020)" do
    test "known_event_types includes handled types" do
      known = IdentifyDomainEvents.known_event_types()
      assert MapSet.member?(known, "MatchGameRoomStateChangedEvent")
      assert MapSet.member?(known, "GreToClientEvent")
    end

    test "known_event_types includes explicitly ignored types" do
      known = IdentifyDomainEvents.known_event_types()
      assert MapSet.member?(known, "GraphGetGraphState")
      assert MapSet.member?(known, "ClientToGreuimessage")
    end

    test "recognized? returns false for unknown types" do
      refute IdentifyDomainEvents.recognized?("SomeNewMtgaEvent")
    end

    test "recognized? returns true for handled types" do
      assert IdentifyDomainEvents.recognized?("MatchGameRoomStateChangedEvent")
    end

    test "recognized? returns true for ignored types" do
      assert IdentifyDomainEvents.recognized?("GraphGetGraphState")
    end
  end
end
