defmodule Scry2.Events.IdentifyDomainEventsTest do
  use ExUnit.Case, async: true

  alias Scry2.Events.Deck.{DeckInventory, DeckSelected, DeckSubmitted, DeckUpdated}

  alias Scry2.Events.Draft.{
    DraftCompleted,
    DraftPickMade,
    DraftStarted,
    HumanDraftPackOffered,
    HumanDraftPickMade
  }

  alias Scry2.Events.Economy.{InventoryChanged, InventoryUpdated}
  alias Scry2.Events.Event.{EventCourseUpdated, EventJoined, EventRewardClaimed, PairingEntered}
  alias Scry2.Events.IdentifyDomainEvents
  alias Scry2.Events.Match.{DieRolled, GameCompleted, MatchCompleted, MatchCreated}
  alias Scry2.Events.Progression.{DailyWinsStatus, MasteryProgress, QuestStatus, RankSnapshot}
  alias Scry2.Events.Gameplay.MulliganDecided
  alias Scry2.Events.Session.{SessionDisconnected, SessionStarted}
  alias Scry2.Events.Turn.TurnStarted
  alias Scry2.Events.TranslationWarning

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

      # self_team is 1 (seat 1, falling back since self_user_id is nil)
      assert Enum.at(event.game_results, 0) == %{
               game_number: 1,
               winning_team_id: 2,
               won: false,
               reason: "ResultReason_Concede"
             }

      assert Enum.at(event.game_results, 1) == %{
               game_number: 2,
               winning_team_id: 1,
               won: true,
               reason: "ResultReason_Concede"
             }

      assert Enum.at(event.game_results, 2) == %{
               game_number: 3,
               winning_team_id: 1,
               won: true,
               reason: "ResultReason_Concede"
             }
    end
  end

  describe "translate/3 — GreToClientEvent with match context map" do
    test "uses current_match_id from match context when event has no match id" do
      record = record_from_fixture("gre_to_client_event_connect_resp.log")

      # IngestRawEvents converts IngestionState.Match to a plain map before
      # calling translate/3, so match_context is always an atom-keyed map.
      match_context = %{
        current_match_id: "008b1926-09a8-40b4-872d-fa987588740c",
        game_objects: %{}
      }

      {events, []} = IdentifyDomainEvents.translate(record, @self_user_id, match_context)

      assert Enum.any?(events, &match?(%DeckSubmitted{}, &1))
    end
  end

  describe "translate/2 — GreToClientEvent, ConnectResp batch" do
    test "produces DeckSubmitted + DieRolled from the ConnectResp fixture" do
      record = record_from_fixture("gre_to_client_event_connect_resp.log")

      {events, []} = IdentifyDomainEvents.translate(record, @self_user_id)

      deck_event = Enum.find(events, &match?(%DeckSubmitted{}, &1))
      die_event = Enum.find(events, &match?(%DieRolled{}, &1))

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

  # Helper to build a minimal GreToClientEvent record with ConnectResp + GameStateMessage.
  # Used to test that GameStateMessage events in the same batch as ConnectResp get the
  # anticipated game_number (Bug 2 fix).
  defp gre_batch_with_connect_resp_and_turn(seat, turn_number) do
    %EventRecord{
      id: 99,
      event_type: "GreToClientEvent",
      mtga_timestamp: ~U[2026-04-05 19:18:40Z],
      file_offset: 0,
      source_file: "Player.log",
      raw_json:
        Jason.encode!(%{
          "greToClientEvent" => %{
            "greToClientMessages" => [
              %{
                "type" => "GREMessageType_ConnectResp",
                "systemSeatIds" => [seat],
                "connectResp" => %{
                  "deckMessage" => %{"deckCards" => [91_234, 91_234], "sideboardCards" => []}
                }
              },
              %{
                "type" => "GREMessageType_GameStateMessage",
                "systemSeatIds" => [seat],
                "gameStateMessage" => %{
                  "gameInfo" => %{"matchID" => "match-abc"},
                  "turnInfo" => %{
                    "turnNumber" => turn_number,
                    "phase" => "Phase_Main1",
                    "activePlayer" => seat
                  }
                }
              }
            ]
          }
        }),
      processed: false
    }
  end

  describe "translate/3 — GreToClientEvent — game_number anticipation for ConnectResp batch" do
    test "GameStateMessage events in ConnectResp batch get game_number=1 for the first game" do
      record = gre_batch_with_connect_resp_and_turn(1, 1)
      match_context = %{current_match_id: "match-abc", current_game_number: nil}

      {events, []} = IdentifyDomainEvents.translate(record, nil, match_context)

      turn_started = Enum.find(events, &match?(%TurnStarted{}, &1))
      assert turn_started != nil, "expected TurnStarted in events: #{inspect(events)}"
      assert turn_started.game_number == 1
    end

    test "GameStateMessage events in ConnectResp batch get anticipated game_number for game 2" do
      record = gre_batch_with_connect_resp_and_turn(1, 1)
      match_context = %{current_match_id: "match-abc", current_game_number: 1}

      {events, []} = IdentifyDomainEvents.translate(record, nil, match_context)

      turn_started = Enum.find(events, &match?(%TurnStarted{}, &1))
      assert turn_started != nil
      assert turn_started.game_number == 2
    end

    test "GameStateMessage events without ConnectResp keep current_game_number unchanged" do
      # A GRE batch without ConnectResp should NOT anticipate a new game number.
      record = %EventRecord{
        id: 99,
        event_type: "GreToClientEvent",
        mtga_timestamp: ~U[2026-04-05 19:18:40Z],
        file_offset: 0,
        source_file: "Player.log",
        raw_json:
          Jason.encode!(%{
            "greToClientEvent" => %{
              "greToClientMessages" => [
                %{
                  "type" => "GREMessageType_GameStateMessage",
                  "systemSeatIds" => [1],
                  "gameStateMessage" => %{
                    "gameInfo" => %{"matchID" => "match-abc"},
                    "turnInfo" => %{
                      "turnNumber" => 3,
                      "phase" => "Phase_Main1",
                      "activePlayer" => 1
                    }
                  }
                }
              ]
            }
          }),
        processed: false
      }

      match_context = %{current_match_id: "match-abc", current_game_number: 1}

      {events, []} = IdentifyDomainEvents.translate(record, nil, match_context)

      turn_started = Enum.find(events, &match?(%TurnStarted{}, &1))
      assert turn_started != nil
      assert turn_started.game_number == 1
    end
  end

  describe "translate/2 — fall-through" do
    test "returns {[], []} for an unrelated raw event type" do
      record = %EventRecord{
        id: 1,
        event_type: "SomeUnknownEvent",
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
      assert MapSet.member?(known, "ClientToGreuimessage")
      assert MapSet.member?(known, "STATE")
    end

    test "recognized? returns false for unknown types" do
      refute IdentifyDomainEvents.recognized?("SomeNewMtgaEvent")
    end

    test "recognized? returns true for handled types" do
      assert IdentifyDomainEvents.recognized?("MatchGameRoomStateChangedEvent")
    end

    test "recognized? returns true for ignored types" do
      assert IdentifyDomainEvents.recognized?("ClientToGreuimessage")
    end

    test "recognized? returns true for new handled types" do
      assert IdentifyDomainEvents.recognized?("EventJoin")
      assert IdentifyDomainEvents.recognized?("EventClaimPrize")
      assert IdentifyDomainEvents.recognized?("EventSetDeckV2")
      assert IdentifyDomainEvents.recognized?("EventEnterPairing")
      assert IdentifyDomainEvents.recognized?("QuestGetQuests")
      assert IdentifyDomainEvents.recognized?("PeriodicRewardsGetStatus")
      assert IdentifyDomainEvents.recognized?("EventGetCoursesV2")
      assert IdentifyDomainEvents.recognized?("DeckGetDeckSummariesV2")
    end

    test "recognized? returns true for newly handled/ignored types" do
      assert IdentifyDomainEvents.recognized?("GraphGetGraphState")
      assert IdentifyDomainEvents.recognized?("DeckDeleteDeck")
      assert IdentifyDomainEvents.recognized?("GetFormats")
      assert IdentifyDomainEvents.recognized?("EventGetActiveMatches")
    end

    test "recognized? returns true for deferred types" do
      assert IdentifyDomainEvents.recognized?("StartHook")
    end

    test "deferred_event_types returns an empty MapSet" do
      assert MapSet.equal?(IdentifyDomainEvents.deferred_event_types(), MapSet.new())
    end
  end

  # ── Seat-2 perspective tests ────────────────────────────────────────
  #
  # MTGA alternates the player between seat 1 and seat 2 across matches.
  # These tests verify that perspective-sensitive fields (self_goes_first,
  # chose_play, won) are correct when the player is seat 2.

  describe "translate/3 — DieRolled with player as seat 2" do
    test "self_goes_first is true when seat-2 player rolled higher" do
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
                %{
                  "type" => "GREMessageType_ConnectResp",
                  "systemSeatIds" => [2],
                  "msgId" => 1,
                  "connectResp" => %{
                    "status" => "ConnectionStatus_Success",
                    "deckMessage" => %{
                      "deckCards" => [91234, 91234, 91234, 91234],
                      "sideboardCards" => []
                    }
                  }
                },
                %{
                  "type" => "GREMessageType_DieRollResultsResp",
                  "systemSeatIds" => [1, 2],
                  "msgId" => 2,
                  "dieRollResultsResp" => %{
                    "playerDieRolls" => [
                      %{"systemSeatId" => 1, "rollValue" => 6},
                      %{"systemSeatId" => 2, "rollValue" => 19}
                    ]
                  }
                }
              ]
            }
          }),
        processed: false
      }

      match_context = %{current_match_id: "seat2-test-match"}

      {events, []} = IdentifyDomainEvents.translate(record, nil, match_context)

      die_event = Enum.find(events, &match?(%DieRolled{}, &1))
      assert die_event != nil
      assert die_event.self_roll == 19
      assert die_event.opponent_roll == 6
      assert die_event.self_goes_first == true
    end

    test "self_goes_first is false when seat-2 player rolled lower" do
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
                %{
                  "type" => "GREMessageType_ConnectResp",
                  "systemSeatIds" => [2],
                  "msgId" => 1,
                  "connectResp" => %{
                    "status" => "ConnectionStatus_Success",
                    "deckMessage" => %{
                      "deckCards" => [91234, 91234, 91234, 91234],
                      "sideboardCards" => []
                    }
                  }
                },
                %{
                  "type" => "GREMessageType_DieRollResultsResp",
                  "systemSeatIds" => [1, 2],
                  "msgId" => 2,
                  "dieRollResultsResp" => %{
                    "playerDieRolls" => [
                      %{"systemSeatId" => 1, "rollValue" => 19},
                      %{"systemSeatId" => 2, "rollValue" => 6}
                    ]
                  }
                }
              ]
            }
          }),
        processed: false
      }

      match_context = %{current_match_id: "seat2-test-match"}

      {events, []} = IdentifyDomainEvents.translate(record, nil, match_context)

      die_event = Enum.find(events, &match?(%DieRolled{}, &1))
      assert die_event != nil
      assert die_event.self_roll == 6
      assert die_event.opponent_roll == 19
      assert die_event.self_goes_first == false
    end
  end

  describe "translate/3 — StartingPlayerChosen with player as seat 2" do
    test "chose_play is true when seat-2 player chose themselves" do
      record = %EventRecord{
        id: 1,
        event_type: "ClientToGremessage",
        mtga_timestamp: ~U[2026-04-05 19:19:00Z],
        file_offset: 0,
        source_file: "Player.log",
        raw_json:
          Jason.encode!(%{
            "type" => "ClientMessageType_ChooseStartingPlayerResp",
            "payload" => %{
              "type" => "ClientMessageType_ChooseStartingPlayerResp",
              "chooseStartingPlayerResp" => %{"systemSeatId" => 2}
            }
          }),
        processed: false
      }

      match_context = %{
        current_match_id: "seat2-test-match",
        self_seat_id: 2
      }

      {[%Scry2.Events.Gameplay.StartingPlayerChosen{} = event], []} =
        IdentifyDomainEvents.translate(record, nil, match_context)

      assert event.chose_play == true
    end

    test "chose_play is false when seat-2 player chose opponent" do
      record = %EventRecord{
        id: 1,
        event_type: "ClientToGremessage",
        mtga_timestamp: ~U[2026-04-05 19:19:00Z],
        file_offset: 0,
        source_file: "Player.log",
        raw_json:
          Jason.encode!(%{
            "type" => "ClientMessageType_ChooseStartingPlayerResp",
            "payload" => %{
              "type" => "ClientMessageType_ChooseStartingPlayerResp",
              "chooseStartingPlayerResp" => %{"systemSeatId" => 1}
            }
          }),
        processed: false
      }

      match_context = %{
        current_match_id: "seat2-test-match",
        self_seat_id: 2
      }

      {[%Scry2.Events.Gameplay.StartingPlayerChosen{} = event], []} =
        IdentifyDomainEvents.translate(record, nil, match_context)

      assert event.chose_play == false
    end
  end

  # ── GraphGetGraphState → MasteryProgress ────────────────────────────

  describe "translate/2 — GraphGetGraphState response → MasteryProgress" do
    test "produces a %MasteryProgress{} from a response event" do
      record = record_from_fixture("graph_get_graph_state_response.log")

      assert {[%MasteryProgress{} = event], []} =
               IdentifyDomainEvents.translate(record, @self_user_id)

      assert event.total_nodes == 8
      assert event.completed_nodes == 7
      assert event.milestone_states == %{"TutorialComplete" => true}
      assert %{"PlayFamiliar1" => %{"Status" => "Completed"}} = event.node_states
      assert %{"Reset" => %{"Status" => "Available"}} = event.node_states
    end

    test "skips request events" do
      record = %EventRecord{
        id: 1,
        event_type: "GraphGetGraphState",
        mtga_timestamp: ~U[2026-04-06 18:47:40Z],
        file_offset: 0,
        source_file: "Player.log",
        raw_json:
          ~s({"id":"6112fce4-9905-4b58-82dc-7a7795f30d2e","request":"{\\"GraphId\\":\\"NPE_Tutorial\\"}"}),
        processed: false
      }

      assert {[], []} = IdentifyDomainEvents.translate(record, @self_user_id)
    end
  end

  # ── EventJoin → EventJoined + InventoryChanged ──────────────────────

  describe "translate/2 — EventJoin response → EventJoined + InventoryChanged" do
    test "produces EventJoined and InventoryChanged from a response" do
      record = %EventRecord{
        id: 1,
        event_type: "EventJoin",
        mtga_timestamp: ~U[2026-04-06 16:30:00Z],
        file_offset: 0,
        source_file: "Player.log",
        raw_json:
          Jason.encode!(%{
            "Course" => %{
              "CourseId" => "e1a4b192-course-uuid",
              "InternalEventName" => "QuickDraft_FDN_20260323"
            },
            "InventoryInfo" => %{
              "Changes" => [
                %{
                  "Source" => "EventPayEntry",
                  "SourceId" => "e1a4b192-course-uuid",
                  "InventoryGold" => -5000
                }
              ],
              "Gold" => 7150,
              "Gems" => 4600
            }
          }),
        processed: false
      }

      assert {events, []} = IdentifyDomainEvents.translate(record, nil)
      assert [%EventJoined{} = joined, %InventoryChanged{} = inv] = events

      assert joined.event_name == "QuickDraft_FDN_20260323"
      assert joined.course_id == "e1a4b192-course-uuid"
      assert joined.entry_currency_type == "Gold"
      assert joined.entry_fee == 5000

      assert inv.source == "EventPayEntry"
      assert inv.gold_delta == -5000
      assert inv.gold_balance == 7150
      assert inv.gems_balance == 4600
    end

    test "skips request-format EventJoin records" do
      record = %EventRecord{
        id: 1,
        event_type: "EventJoin",
        file_offset: 0,
        source_file: "Player.log",
        raw_json:
          Jason.encode!(%{
            "id" => "uuid",
            "request" => ~s({"EventName":"QuickDraft_FDN_20260323"})
          }),
        processed: false
      }

      assert {[], []} = IdentifyDomainEvents.translate(record, nil)
    end
  end

  # ── EventJoin (CurrentModule=PlayerDraft) → DraftStarted ────────────

  describe "translate/2 — EventJoin response (PlayerDraft) → DraftStarted" do
    test "PickTwoDraft: emits DraftStarted with CourseId as mtga_draft_id" do
      record = record_from_fixture("event_join_pick_two_draft_response.log")

      assert {events, []} = IdentifyDomainEvents.translate(record, nil)

      started = Enum.find(events, &is_struct(&1, DraftStarted))
      assert started, "expected a DraftStarted in #{inspect(events)}"
      assert started.mtga_draft_id == "500a621e-a42b-4965-9e4c-720fe05307c7"
      assert started.event_name == "PickTwoDraft_SOS_20260421"
      assert started.set_code == "SOS"

      assert Enum.find(events, &is_struct(&1, EventJoined))
    end

    test "non-draft EventJoin (CurrentModule=CreateMatch) does not emit DraftStarted" do
      record = %EventRecord{
        id: 1,
        event_type: "EventJoin",
        mtga_timestamp: ~U[2026-04-27 16:30:00Z],
        file_offset: 0,
        source_file: "Player.log",
        raw_json:
          Jason.encode!(%{
            "Course" => %{
              "CourseId" => "00000000-0000-0000-0000-000000000001",
              "InternalEventName" => "Traditional_Ladder",
              "CurrentModule" => "CreateMatch"
            },
            "InventoryInfo" => %{"Changes" => []}
          }),
        processed: false
      }

      assert {events, []} = IdentifyDomainEvents.translate(record, nil)
      refute Enum.any?(events, &is_struct(&1, DraftStarted))
    end

    test "EventJoin with no CurrentModule does not emit DraftStarted" do
      record = %EventRecord{
        id: 1,
        event_type: "EventJoin",
        mtga_timestamp: ~U[2026-04-27 16:30:00Z],
        file_offset: 0,
        source_file: "Player.log",
        raw_json:
          Jason.encode!(%{
            "Course" => %{
              "CourseId" => "00000000-0000-0000-0000-000000000002",
              "InternalEventName" => "Traditional_Ladder"
            },
            "InventoryInfo" => %{"Changes" => []}
          }),
        processed: false
      }

      assert {events, []} = IdentifyDomainEvents.translate(record, nil)
      refute Enum.any?(events, &is_struct(&1, DraftStarted))
    end
  end

  # ── DraftCompleteDraft (CourseId-keyed) → DraftCompleted ────────────

  describe "translate/2 — DraftCompleteDraft response → DraftCompleted (CourseId)" do
    test "PickTwoDraft: produces DraftCompleted keyed on CourseId" do
      record = record_from_fixture("draft_complete_draft_pick_two_response.log")

      assert {[%DraftCompleted{} = event], []} = IdentifyDomainEvents.translate(record, nil)
      assert event.mtga_draft_id == "500a621e-a42b-4965-9e4c-720fe05307c7"
      assert event.event_name == "PickTwoDraft_SOS_20260421"
      assert event.is_bot_draft == false
      assert length(event.card_pool_arena_ids) == 42
    end

    test "PremierDraft: produces DraftCompleted keyed on CourseId" do
      record = record_from_fixture("draft_complete_draft_premier_response.log")

      assert {[%DraftCompleted{} = event], []} = IdentifyDomainEvents.translate(record, nil)
      assert event.mtga_draft_id == "472a1bd8-e661-49c9-b39e-ea25a4bd79bc"
      assert event.event_name == "PremierDraft_SOS_20260421"
      assert event.is_bot_draft == false
      assert length(event.card_pool_arena_ids) == 42
    end
  end

  # ── EventClaimPrize → EventRewardClaimed + InventoryUpdated ─────────

  describe "translate/2 — EventClaimPrize response → EventRewardClaimed + InventoryUpdated" do
    test "produces EventRewardClaimed and InventoryUpdated with reward details" do
      record = %EventRecord{
        id: 1,
        event_type: "EventClaimPrize",
        mtga_timestamp: ~U[2026-04-06 19:20:00Z],
        file_offset: 0,
        source_file: "Player.log",
        raw_json:
          Jason.encode!(%{
            "Course" => %{
              "CourseId" => "e1a4b192-course-uuid",
              "InternalEventName" => "QuickDraft_FDN_20260323",
              "CurrentWins" => 3,
              "CurrentLosses" => 3,
              "CardPool" => [12345, 67890]
            },
            "InventoryInfo" => %{
              "Changes" => [
                %{
                  "Source" => "EventReward",
                  "SourceId" => "e1a4b192-course-uuid",
                  "InventoryGems" => 300,
                  "Boosters" => [%{"SetCode" => "FDN", "Count" => 1}]
                }
              ],
              "Gold" => 8200,
              "Gems" => 4900,
              "WildCardCommons" => 2,
              "WildCardUnCommons" => 1,
              "WildCardRares" => 0,
              "WildCardMythics" => 0,
              "TotalVaultProgress" => 150
            }
          }),
        processed: false
      }

      assert {events, []} = IdentifyDomainEvents.translate(record, nil)
      assert [%EventRewardClaimed{} = reward, %InventoryUpdated{} = inv] = events

      assert reward.event_name == "QuickDraft_FDN_20260323"
      assert reward.final_wins == 3
      assert reward.final_losses == 3
      assert reward.gems_awarded == 300
      assert reward.boosters_awarded == [%{"SetCode" => "FDN", "Count" => 1}]
      assert reward.card_pool == [12345, 67890]

      assert inv.gold == 8200
      assert inv.gems == 4900
      assert inv.wildcards_common == 2
      assert inv.vault_progress == 15.0
    end
  end

  # ── EventEnterPairing → PairingEntered ──────────────────────────────

  describe "translate/2 — EventEnterPairing → PairingEntered" do
    test "produces PairingEntered from a request" do
      record = %EventRecord{
        id: 1,
        event_type: "EventEnterPairing",
        mtga_timestamp: ~U[2026-04-06 19:00:00Z],
        file_offset: 0,
        source_file: "Player.log",
        raw_json:
          Jason.encode!(%{
            "id" => "uuid",
            "request" => ~s({"EventName":"QuickDraft_FDN_20260323","EventCode":null})
          }),
        processed: false
      }

      assert {[%PairingEntered{} = event], []} = IdentifyDomainEvents.translate(record, nil)
      assert event.event_name == "QuickDraft_FDN_20260323"
    end
  end

  # ── EventSetDeckV2 → DeckSelected ──────────────────────────────────

  describe "translate/2 — EventSetDeckV2 → DeckSelected" do
    test "produces DeckSelected with full deck list from request" do
      record = %EventRecord{
        id: 1,
        event_type: "EventSetDeckV2",
        mtga_timestamp: ~U[2026-04-06 18:58:00Z],
        file_offset: 0,
        source_file: "Player.log",
        raw_json:
          Jason.encode!(%{
            "id" => "uuid",
            "request" =>
              Jason.encode!(%{
                "EventName" => "QuickDraft_FDN_20260323",
                "Summary" => %{
                  "DeckId" => "4fdde14e-deck-uuid",
                  "Name" => "Draft Deck"
                },
                "Deck" => %{
                  "MainDeck" => [
                    %{"cardId" => 93811, "quantity" => 3},
                    %{"cardId" => 93939, "quantity" => 1}
                  ],
                  "Sideboard" => [
                    %{"cardId" => 93959, "quantity" => 1}
                  ]
                }
              })
          }),
        processed: false
      }

      assert {[%DeckSelected{} = event], []} = IdentifyDomainEvents.translate(record, nil)
      assert event.event_name == "QuickDraft_FDN_20260323"
      assert event.deck_id == "4fdde14e-deck-uuid"
      assert event.deck_name == "Draft Deck"
      assert length(event.main_deck) == 2
      assert hd(event.main_deck) == %{arena_id: 93811, count: 3}
      assert event.sideboard == [%{arena_id: 93959, count: 1}]
    end
  end

  # ── DeckUpsertDeckV2 → DeckUpdated ──────────────────────────────────

  describe "translate/2 — DeckUpsertDeckV2 → DeckUpdated" do
    test "produces DeckUpdated with full deck and action type" do
      record = %EventRecord{
        id: 1,
        event_type: "DeckUpsertDeckV2",
        mtga_timestamp: ~U[2026-04-07 07:21:54Z],
        file_offset: 0,
        source_file: "Player.log",
        raw_json:
          Jason.encode!(%{
            "id" => "uuid",
            "request" =>
              Jason.encode!(%{
                "Summary" => %{
                  "DeckId" => "c827dfd7-deck-uuid",
                  "Name" => "WB TMT Draft (2)",
                  "Attributes" => [
                    %{"name" => "Format", "value" => "DirectGameLimited"}
                  ]
                },
                "Deck" => %{
                  "MainDeck" => [
                    %{"cardId" => 100_534, "quantity" => 1},
                    %{"cardId" => 100_514, "quantity" => 1}
                  ],
                  "Sideboard" => [
                    %{"cardId" => 100_525, "quantity" => 1}
                  ]
                },
                "ActionType" => "Cloned"
              })
          }),
        processed: false
      }

      assert {[%DeckUpdated{} = event], []} = IdentifyDomainEvents.translate(record, nil)
      assert event.deck_id == "c827dfd7-deck-uuid"
      assert event.deck_name == "WB TMT Draft (2)"
      # "DirectGameLimited" is an event-type string, not a real format —
      # normalize_deck_format/1 filters it to nil
      assert event.format == nil
      assert event.action_type == "Cloned"
      assert length(event.main_deck) == 2
      assert event.sideboard == [%{arena_id: 100_525, count: 1}]
    end
  end

  # ── DeckGetDeckSummariesV2 → DeckInventory ─────────────────────────

  describe "translate/2 — DeckGetDeckSummariesV2 → DeckInventory" do
    test "produces DeckInventory from response" do
      record = %EventRecord{
        id: 1,
        event_type: "DeckGetDeckSummariesV2",
        mtga_timestamp: ~U[2026-04-06 16:00:00Z],
        file_offset: 0,
        source_file: "Player.log",
        raw_json:
          Jason.encode!(%{
            "Summaries" => [
              %{
                "DeckId" => "deck-1",
                "Name" => "Mono Red",
                "Attributes" => [%{"name" => "Format", "value" => "Standard"}]
              },
              %{
                "DeckId" => "deck-2",
                "Name" => "Draft Deck",
                "Attributes" => [%{"name" => "Format", "value" => "Draft"}]
              }
            ]
          }),
        processed: false
      }

      assert {[%DeckInventory{} = event], []} = IdentifyDomainEvents.translate(record, nil)
      assert length(event.decks) == 2
      assert hd(event.decks) == %{deck_id: "deck-1", name: "Mono Red", format: "Standard"}
    end

    test "skips request-format records" do
      record = %EventRecord{
        id: 1,
        event_type: "DeckGetDeckSummariesV2",
        file_offset: 0,
        source_file: "Player.log",
        raw_json: ~s({"id":"uuid","request":"{}"}),
        processed: false
      }

      assert {[], []} = IdentifyDomainEvents.translate(record, nil)
    end
  end

  # ── QuestGetQuests → QuestStatus ───────────────────────────────────

  describe "translate/2 — QuestGetQuests → QuestStatus" do
    test "produces QuestStatus from response" do
      record = %EventRecord{
        id: 1,
        event_type: "QuestGetQuests",
        mtga_timestamp: ~U[2026-04-06 16:00:00Z],
        file_offset: 0,
        source_file: "Player.log",
        raw_json:
          Jason.encode!(%{
            "quests" => [
              %{
                "questId" => "quest-uuid-1",
                "goal" => 30,
                "endingProgress" => 7,
                "questTrack" => "Default",
                "chestDescription" => %{
                  "locParams" => %{"number1" => 750, "number2" => 500}
                }
              }
            ]
          }),
        processed: false
      }

      assert {[%QuestStatus{} = event], []} = IdentifyDomainEvents.translate(record, nil)
      assert length(event.quests) == 1
      quest = hd(event.quests)
      assert quest.quest_id == "quest-uuid-1"
      assert quest.goal == 30
      assert quest.progress == 7
      assert quest.reward_gold == 750
      assert quest.reward_xp == 500
    end

    test "skips request-format records" do
      record = %EventRecord{
        id: 1,
        event_type: "QuestGetQuests",
        file_offset: 0,
        source_file: "Player.log",
        raw_json: ~s({"id":"uuid","request":"{}"}),
        processed: false
      }

      assert {[], []} = IdentifyDomainEvents.translate(record, nil)
    end
  end

  # ── PeriodicRewardsGetStatus → DailyWinsStatus ─────────────────────

  describe "translate/2 — PeriodicRewardsGetStatus → DailyWinsStatus" do
    test "produces DailyWinsStatus from response" do
      record = %EventRecord{
        id: 1,
        event_type: "PeriodicRewardsGetStatus",
        mtga_timestamp: ~U[2026-04-06 16:00:00Z],
        file_offset: 0,
        source_file: "Player.log",
        raw_json:
          Jason.encode!(%{
            "_dailyRewardSequenceId" => 1,
            "_dailyRewardResetTimestamp" => "2026-04-07T09:00:00Z",
            "_weeklyRewardSequenceId" => 15,
            "_weeklyRewardResetTimestamp" => "2026-04-12T09:00:00Z",
            "_dailyRewardChestDescriptions" => %{},
            "_weeklyRewardChestDescriptions" => %{}
          }),
        processed: false
      }

      assert {[%DailyWinsStatus{} = event], []} = IdentifyDomainEvents.translate(record, nil)
      assert event.daily_position == 1
      assert event.daily_reset_at == ~U[2026-04-07 09:00:00Z]
      assert event.weekly_position == 15
      assert event.weekly_reset_at == ~U[2026-04-12 09:00:00Z]
    end

    test "skips request-format records" do
      record = %EventRecord{
        id: 1,
        event_type: "PeriodicRewardsGetStatus",
        file_offset: 0,
        source_file: "Player.log",
        raw_json: ~s({"id":"uuid","request":"{}"}),
        processed: false
      }

      assert {[], []} = IdentifyDomainEvents.translate(record, nil)
    end
  end

  # ── EventGetCoursesV2 → EventCourseUpdated (per course) ─────────────

  describe "translate/2 — EventGetCoursesV2 → EventCourseUpdated per course" do
    test "produces one EventCourseUpdated per course with non-empty event name" do
      record = %EventRecord{
        id: 1,
        event_type: "EventGetCoursesV2",
        mtga_timestamp: ~U[2026-04-06 16:00:00Z],
        file_offset: 0,
        source_file: "Player.log",
        raw_json:
          Jason.encode!(%{
            "Courses" => [
              %{
                "CourseId" => "course-1",
                "InternalEventName" => "QuickDraft_FDN_20260323",
                "CurrentModule" => "BotDraft",
                "CurrentWins" => 2,
                "CurrentLosses" => 1,
                "CardPool" => [11111, 22222]
              },
              %{
                "CourseId" => "course-2",
                "InternalEventName" => "DualColorPrecons",
                "CurrentModule" => "CreateMatch",
                "CurrentWins" => 10,
                "CurrentLosses" => 5,
                "CardPool" => nil
              }
            ]
          }),
        processed: false
      }

      assert {events, []} = IdentifyDomainEvents.translate(record, nil)
      assert length(events) == 2
      assert Enum.all?(events, &match?(%EventCourseUpdated{}, &1))

      [draft, constructed] = events
      assert draft.event_name == "QuickDraft_FDN_20260323"
      assert draft.current_wins == 2
      assert draft.current_losses == 1
      assert draft.current_module == "BotDraft"
      assert draft.card_pool == [11111, 22222]

      assert constructed.event_name == "DualColorPrecons"
      assert constructed.current_wins == 10
    end

    test "filters out courses with empty or nil InternalEventName" do
      record = %EventRecord{
        id: 1,
        event_type: "EventGetCoursesV2",
        mtga_timestamp: ~U[2026-04-06 16:00:00Z],
        file_offset: 0,
        source_file: "Player.log",
        raw_json:
          Jason.encode!(%{
            "Courses" => [
              %{"InternalEventName" => "ValidEvent", "CurrentWins" => 0, "CurrentLosses" => 0},
              %{"InternalEventName" => "", "CurrentWins" => 0, "CurrentLosses" => 0},
              %{"InternalEventName" => nil, "CurrentWins" => 0, "CurrentLosses" => 0}
            ]
          }),
        processed: false
      }

      assert {[%EventCourseUpdated{event_name: "ValidEvent"}], []} =
               IdentifyDomainEvents.translate(record, nil)
    end

    test "skips request-format records" do
      record = %EventRecord{
        id: 1,
        event_type: "EventGetCoursesV2",
        file_offset: 0,
        source_file: "Player.log",
        raw_json: ~s({"id":"uuid","request":"{}"}),
        processed: false
      }

      assert {[], []} = IdentifyDomainEvents.translate(record, nil)
    end
  end

  # ── StartHook → InventoryUpdated ─────────────────────────────────────

  describe "translate/2 — StartHook → InventoryUpdated" do
    test "produces InventoryUpdated from login hook with InventoryInfo" do
      record = %EventRecord{
        id: 1,
        event_type: "StartHook",
        mtga_timestamp: ~U[2026-04-07 09:00:00Z],
        file_offset: 0,
        source_file: "Player.log",
        raw_json:
          Jason.encode!(%{
            "InventoryInfo" => %{
              "Gold" => 12500,
              "Gems" => 3200,
              "WildCardCommons" => 8,
              "WildCardUnCommons" => 4,
              "WildCardRares" => 2,
              "WildCardMythics" => 1,
              "TotalVaultProgress" => 475
            }
          }),
        processed: false
      }

      assert {[%InventoryUpdated{} = event], []} = IdentifyDomainEvents.translate(record, nil)
      assert event.gold == 12500
      assert event.gems == 3200
      assert event.wildcards_common == 8
      assert event.wildcards_uncommon == 4
      assert event.wildcards_rare == 2
      assert event.wildcards_mythic == 1
      assert event.vault_progress == 47.5
    end

    test "returns empty list when InventoryInfo is absent (empty-payload login)" do
      record = %EventRecord{
        id: 1,
        event_type: "StartHook",
        file_offset: 0,
        source_file: "Player.log",
        raw_json: "{}",
        processed: false
      }

      assert {[], []} = IdentifyDomainEvents.translate(record, nil)
    end
  end

  # ── Draft.Notify → HumanDraftPackOffered ────────────────────────────

  describe "translate/2 — Draft.Notify response → HumanDraftPackOffered" do
    test "produces HumanDraftPackOffered with pack contents" do
      record = %EventRecord{
        id: 1,
        event_type: "Draft.Notify",
        mtga_timestamp: ~U[2026-04-08 14:00:00Z],
        file_offset: 0,
        source_file: "Player.log",
        raw_json:
          Jason.encode!(%{
            "draftId" => "draft-abc-001",
            "SelfPack" => 1,
            "SelfPick" => 2,
            "PackCards" => "12345,67890,11111"
          }),
        processed: false
      }

      assert {[%HumanDraftPackOffered{} = event], []} =
               IdentifyDomainEvents.translate(record, nil)

      assert event.mtga_draft_id == "draft-abc-001"
      assert event.pack_number == 1
      assert event.pick_number == 2
      assert event.pack_arena_ids == [12345, 67890, 11111]
      assert event.occurred_at == ~U[2026-04-08 14:00:00Z]
    end

    test "skips Draft.Notify records that are RPC metadata (have a method key)" do
      record = %EventRecord{
        id: 1,
        event_type: "Draft.Notify",
        file_offset: 0,
        source_file: "Player.log",
        raw_json:
          Jason.encode!(%{
            "method" => "Draft.Notify",
            "id" => "some-rpc-id"
          }),
        processed: false
      }

      assert {[], []} = IdentifyDomainEvents.translate(record, nil)
    end
  end

  # ── EventPlayerDraftMakePick → HumanDraftPickMade ───────────────────

  describe "translate/2 — EventPlayerDraftMakePick response → HumanDraftPickMade" do
    test "produces HumanDraftPickMade with selected card" do
      record = %EventRecord{
        id: 1,
        event_type: "EventPlayerDraftMakePick",
        mtga_timestamp: ~U[2026-04-08 14:01:00Z],
        file_offset: 0,
        source_file: "Player.log",
        raw_json:
          Jason.encode!(%{
            "DraftId" => "draft-abc-001",
            "Pack" => 1,
            "Pick" => 2,
            "GrpIds" => [12345]
          }),
        processed: false
      }

      assert {[%HumanDraftPickMade{} = event], []} =
               IdentifyDomainEvents.translate(record, nil)

      assert event.mtga_draft_id == "draft-abc-001"
      assert event.pack_number == 1
      assert event.pick_number == 2
      assert event.picked_arena_ids == [12345]
      assert event.occurred_at == ~U[2026-04-08 14:01:00Z]
    end

    test "handles Pick Two Draft with multiple selected cards" do
      record = %EventRecord{
        id: 1,
        event_type: "EventPlayerDraftMakePick",
        mtga_timestamp: ~U[2026-04-08 14:02:00Z],
        file_offset: 0,
        source_file: "Player.log",
        raw_json:
          Jason.encode!(%{
            "DraftId" => "draft-abc-002",
            "Pack" => 2,
            "Pick" => 5,
            "GrpIds" => [11111, 22222]
          }),
        processed: false
      }

      assert {[%HumanDraftPickMade{} = event], []} =
               IdentifyDomainEvents.translate(record, nil)

      assert event.picked_arena_ids == [11111, 22222]
    end

    test "skips request-format EventPlayerDraftMakePick records" do
      record = %EventRecord{
        id: 1,
        event_type: "EventPlayerDraftMakePick",
        file_offset: 0,
        source_file: "Player.log",
        raw_json:
          Jason.encode!(%{
            "request" => ~s({"DraftId":"draft-abc-001","Pack":1,"Pick":2,"GrpId":12345})
          }),
        processed: false
      }

      assert {[], []} = IdentifyDomainEvents.translate(record, nil)
    end

    test "skips ack-format EventPlayerDraftMakePick records (both flags)" do
      # The server emits a follow-up acknowledgement after each pick
      # with just `IsPickingCompleted` / `IsPickSuccessful` flags. The
      # picked card lives on the *other* response shape (GrpIds +
      # DraftId), which already produces the HumanDraftPickMade event
      # — the ack is genuinely noise.
      record = %EventRecord{
        id: 1,
        event_type: "EventPlayerDraftMakePick",
        file_offset: 0,
        source_file: "Player.log",
        raw_json: ~s({"IsPickingCompleted":true,"IsPickSuccessful":true}),
        processed: false
      }

      assert {[], []} = IdentifyDomainEvents.translate(record, nil)
    end

    test "skips ack-format with only IsPickSuccessful flag" do
      # The pick-success-only shape is the most common ack — fired
      # for every individual pick MTGA confirms. Has no GrpIds /
      # DraftId so there's nothing to translate.
      record = %EventRecord{
        id: 1,
        event_type: "EventPlayerDraftMakePick",
        file_offset: 0,
        source_file: "Player.log",
        raw_json: ~s({"IsPickSuccessful":true}),
        processed: false
      }

      assert {[], []} = IdentifyDomainEvents.translate(record, nil)
    end
  end

  # ── DraftCompleteDraft → DraftCompleted ────────────────────────────

  describe "translate/2 — DraftCompleteDraft → DraftCompleted" do
    test "produces a %DraftCompleted{} with the expected fields" do
      record = %EventRecord{
        id: 1,
        event_type: "DraftCompleteDraft",
        mtga_timestamp: ~U[2026-04-06 12:30:00Z],
        file_offset: 0,
        source_file: "Player.log",
        raw_json:
          Jason.encode!(%{
            "CourseId" => "abc12345-6789-4abc-9def-0123456789ab",
            "InternalEventName" => "PremierDraft_FDN_20260401",
            "CardPool" => [91234, 91235, 91236, 91237]
          }),
        processed: false
      }

      assert {[%DraftCompleted{} = event], []} =
               IdentifyDomainEvents.translate(record, nil)

      assert event.mtga_draft_id == "abc12345-6789-4abc-9def-0123456789ab"
      assert event.event_name == "PremierDraft_FDN_20260401"
      assert event.is_bot_draft == false
      assert event.card_pool_arena_ids == [91234, 91235, 91236, 91237]
      assert event.occurred_at == ~U[2026-04-06 12:30:00Z]
    end

    test "skips request-format DraftCompleteDraft events" do
      record = %EventRecord{
        id: 1,
        event_type: "DraftCompleteDraft",
        file_offset: 0,
        source_file: "Player.log",
        raw_json:
          Jason.encode!(%{
            "request" => ~s({"EventName":"PremierDraft_FDN_20260401"})
          }),
        processed: false
      }

      assert {[], []} = IdentifyDomainEvents.translate(record, nil)
    end
  end

  # ── FrontDoorConnection.Close → SessionDisconnected ────────────────

  describe "translate/2 — FrontDoorConnection.Close → SessionDisconnected" do
    test "produces a %SessionDisconnected{} with the timestamp" do
      record = %EventRecord{
        id: 1,
        event_type: "FrontDoorConnection.Close",
        mtga_timestamp: ~U[2026-04-06 14:00:00Z],
        file_offset: 0,
        source_file: "Player.log",
        raw_json: ~s({}),
        processed: false
      }

      assert {[%SessionDisconnected{} = event], []} =
               IdentifyDomainEvents.translate(record, nil)

      assert event.occurred_at == ~U[2026-04-06 14:00:00Z]
    end
  end

  # ── ClientToGremessage MulliganResp → MulliganDecided ──────────────

  describe "translate/3 — ClientToGremessage MulliganResp → MulliganDecided" do
    test "AcceptHand maps to decision 'keep'" do
      record = %EventRecord{
        id: 1,
        event_type: "ClientToGremessage",
        mtga_timestamp: ~U[2026-04-05 19:20:00Z],
        file_offset: 0,
        source_file: "Player.log",
        raw_json:
          Jason.encode!(%{
            "type" => "ClientMessageType_MulliganResp",
            "payload" => %{
              "type" => "ClientMessageType_MulliganResp",
              "mulliganResp" => %{"decision" => "MulliganOption_AcceptHand"}
            }
          }),
        processed: false
      }

      match_context = %{
        current_match_id: "mulligan-test-match",
        self_seat_id: 1
      }

      {[%MulliganDecided{} = event], []} =
        IdentifyDomainEvents.translate(record, nil, match_context)

      assert event.mtga_match_id == "mulligan-test-match"
      assert event.decision == "keep"
      assert event.occurred_at == ~U[2026-04-05 19:20:00Z]
    end

    test "Mulligan maps to decision 'mulligan'" do
      record = %EventRecord{
        id: 1,
        event_type: "ClientToGremessage",
        mtga_timestamp: ~U[2026-04-05 19:20:05Z],
        file_offset: 0,
        source_file: "Player.log",
        raw_json:
          Jason.encode!(%{
            "type" => "ClientMessageType_MulliganResp",
            "payload" => %{
              "type" => "ClientMessageType_MulliganResp",
              "mulliganResp" => %{"decision" => "MulliganOption_Mulligan"}
            }
          }),
        processed: false
      }

      match_context = %{
        current_match_id: "mulligan-test-match",
        self_seat_id: 1
      }

      {[%MulliganDecided{} = event], []} =
        IdentifyDomainEvents.translate(record, nil, match_context)

      assert event.mtga_match_id == "mulligan-test-match"
      assert event.decision == "mulligan"
      assert event.occurred_at == ~U[2026-04-05 19:20:05Z]
    end
  end

  describe "translate/2 — DeckUpsertDeckV3 request" do
    test "produces a %DeckUpdated{} with deck_id, deck_name, action_type, and card lists" do
      record = record_from_fixture("deck_upsert_deck_v3_request.log")

      assert {[%DeckUpdated{} = event], []} =
               IdentifyDomainEvents.translate(record, @self_user_id)

      assert event.deck_id == "27b5d2a9-2ce6-440e-81cd-c809e90e5f14"
      assert event.deck_name == "North Wind Omni"
      assert event.action_type == "Updated"
      assert length(event.main_deck) > 0
      assert length(event.sideboard) > 0
    end
  end

  describe "translate/2 — DeckUpsertDeckV3 response" do
    test "produces no events (slim response carries no card list)" do
      record = record_from_fixture("deck_upsert_deck_v3_response.log")
      assert {[], []} = IdentifyDomainEvents.translate(record, @self_user_id)
    end
  end

  describe "translate/2 — EventSetDeckV3 request" do
    test "produces a %DeckSelected{} with event_name, deck_id, and card lists" do
      record = record_from_fixture("event_set_deck_v3_request.log")

      assert {[%DeckSelected{} = event], []} =
               IdentifyDomainEvents.translate(record, @self_user_id)

      assert event.event_name == "Traditional_Ladder"
      assert event.deck_id == "27b5d2a9-2ce6-440e-81cd-c809e90e5f14"
      assert event.deck_name == "North Wind Omni"
      assert length(event.main_deck) > 0
    end
  end

  describe "translate/2 — EventSetDeckV3 response" do
    test "produces no events (request already captured the deck selection)" do
      record = record_from_fixture("event_set_deck_v3_response.log")
      assert {[], []} = IdentifyDomainEvents.translate(record, @self_user_id)
    end
  end

  # ── game_number on annotation-derived events (Bug 3) ────────────────
  #
  # CombatDamageDealt, LifeTotalChanged, TokenCreated, and CounterAdded are
  # produced from GameStateMessage annotations. They previously lacked the
  # game_number field entirely — the annotation_to_turn_actions clauses
  # received _game_number (unused). This describe block asserts that each
  # event type now carries game_number from match_context.

  describe "translate/3 — GreToClientEvent — game_number on annotation events" do
    test "CombatDamageDealt carries game_number from match_context" do
      record = gre_batch_with_damage_annotation(1)
      match_context = %{current_match_id: "match-abc", current_game_number: 2}

      {events, []} = IdentifyDomainEvents.translate(record, nil, match_context)

      damage = Enum.find(events, &match?(%Scry2.Events.Gameplay.CombatDamageDealt{}, &1))
      assert damage != nil, "expected CombatDamageDealt in events: #{inspect(events)}"
      assert damage.game_number == 2
    end

    test "LifeTotalChanged carries game_number from match_context" do
      record = gre_batch_with_life_annotation(1)
      match_context = %{current_match_id: "match-abc", current_game_number: 1}

      {events, []} = IdentifyDomainEvents.translate(record, nil, match_context)

      life = Enum.find(events, &match?(%Scry2.Events.Gameplay.LifeTotalChanged{}, &1))
      assert life != nil, "expected LifeTotalChanged in events: #{inspect(events)}"
      assert life.game_number == 1
    end

    test "TokenCreated carries game_number from match_context" do
      record = gre_batch_with_token_annotation(1)
      match_context = %{current_match_id: "match-abc", current_game_number: 3}

      {events, []} = IdentifyDomainEvents.translate(record, nil, match_context)

      token = Enum.find(events, &match?(%Scry2.Events.Gameplay.TokenCreated{}, &1))
      assert token != nil, "expected TokenCreated in events: #{inspect(events)}"
      assert token.game_number == 3
    end

    test "CounterAdded carries game_number from match_context" do
      record = gre_batch_with_counter_annotation(1)
      match_context = %{current_match_id: "match-abc", current_game_number: 2}

      {events, []} = IdentifyDomainEvents.translate(record, nil, match_context)

      counter = Enum.find(events, &match?(%Scry2.Events.Gameplay.CounterAdded{}, &1))
      assert counter != nil, "expected CounterAdded in events: #{inspect(events)}"
      assert counter.game_number == 2
    end
  end

  # ── game_number on game-scoped events (Bug 4) ────────────────────────
  #
  # MulliganOffered, DieRolled (from GreToClientEvent) and MulliganDecided,
  # StartingPlayerChosen, GameConceded (from ClientToGremessage) all occur
  # within a specific game but previously had no game_number field.

  describe "translate/3 — GreToClientEvent — game_number on MulliganOffered" do
    test "MulliganOffered carries game_number from match_context" do
      record = gre_batch_with_mulligan_req(1)
      match_context = %{current_match_id: "match-abc", current_game_number: 1}

      {events, []} = IdentifyDomainEvents.translate(record, nil, match_context)

      mulligan = Enum.find(events, &match?(%Scry2.Events.Gameplay.MulliganOffered{}, &1))
      assert mulligan != nil, "expected MulliganOffered in events: #{inspect(events)}"
      assert mulligan.game_number == 1
    end
  end

  describe "translate/3 — GreToClientEvent — game_number on DieRolled" do
    test "DieRolled carries game_number from match_context" do
      record = gre_batch_with_die_roll(1)
      match_context = %{current_match_id: "match-abc", current_game_number: 1}

      {events, []} = IdentifyDomainEvents.translate(record, nil, match_context)

      die_roll = Enum.find(events, &match?(%Scry2.Events.Match.DieRolled{}, &1))
      assert die_roll != nil, "expected DieRolled in events: #{inspect(events)}"
      assert die_roll.game_number == 1
    end
  end

  describe "translate/3 — ClientToGremessage — game_number on game-scoped events" do
    test "MulliganDecided carries game_number from match_context" do
      record = %EventRecord{
        id: 1,
        event_type: "ClientToGremessage",
        mtga_timestamp: ~U[2026-04-05 19:20:00Z],
        file_offset: 0,
        source_file: "Player.log",
        raw_json:
          Jason.encode!(%{
            "type" => "ClientMessageType_MulliganResp",
            "payload" => %{
              "type" => "ClientMessageType_MulliganResp",
              "mulliganResp" => %{"decision" => "MulliganOption_AcceptHand"}
            }
          }),
        processed: false
      }

      match_context = %{current_match_id: "match-abc", current_game_number: 2}

      {[%MulliganDecided{} = event], []} =
        IdentifyDomainEvents.translate(record, nil, match_context)

      assert event.game_number == 2
    end

    test "StartingPlayerChosen carries game_number from match_context" do
      record = %EventRecord{
        id: 1,
        event_type: "ClientToGremessage",
        mtga_timestamp: ~U[2026-04-05 19:20:00Z],
        file_offset: 0,
        source_file: "Player.log",
        raw_json:
          Jason.encode!(%{
            "type" => "ClientMessageType_ChooseStartingPlayerResp",
            "payload" => %{
              "type" => "ClientMessageType_ChooseStartingPlayerResp",
              "chooseStartingPlayerResp" => %{"systemSeatId" => 1}
            }
          }),
        processed: false
      }

      match_context = %{current_match_id: "match-abc", current_game_number: 1, self_seat_id: 1}

      {[%Scry2.Events.Gameplay.StartingPlayerChosen{} = event], []} =
        IdentifyDomainEvents.translate(record, nil, match_context)

      assert event.game_number == 1
    end

    test "GameConceded carries game_number from match_context" do
      record = %EventRecord{
        id: 1,
        event_type: "ClientToGremessage",
        mtga_timestamp: ~U[2026-04-05 19:25:00Z],
        file_offset: 0,
        source_file: "Player.log",
        raw_json:
          Jason.encode!(%{
            "type" => "ClientMessageType_ConcedeReq",
            "payload" => %{
              "type" => "ClientMessageType_ConcedeReq",
              "concedeReq" => %{"scope" => "game"}
            }
          }),
        processed: false
      }

      match_context = %{current_match_id: "match-abc", current_game_number: 2}

      {[%Scry2.Events.Gameplay.GameConceded{} = event], []} =
        IdentifyDomainEvents.translate(record, nil, match_context)

      assert event.game_number == 2
    end
  end

  # ── Helpers for Bug 3/4 tests ────────────────────────────────────────

  defp gre_batch_with_damage_annotation(seat) do
    gre_batch_with_annotation(seat, %{
      "type" => ["AnnotationType_DamageDealt"],
      "affectorId" => 100,
      "details" => [%{"key" => "damage", "valueInt32" => [3]}]
    })
  end

  defp gre_batch_with_life_annotation(seat) do
    gre_batch_with_annotation(seat, %{
      "type" => ["AnnotationType_ModifiedLife"],
      "affectedIds" => [1],
      "details" => [%{"key" => "life", "valueInt32" => [-2]}]
    })
  end

  defp gre_batch_with_token_annotation(seat) do
    gre_batch_with_annotation(seat, %{
      "type" => ["AnnotationType_TokenCreated"],
      "affectedIds" => [200]
    })
  end

  defp gre_batch_with_counter_annotation(seat) do
    gre_batch_with_annotation(seat, %{
      "type" => ["AnnotationType_CounterAdded"],
      "affectedIds" => [300],
      "details" => [%{"key" => "transaction_amount", "valueInt32" => [1]}]
    })
  end

  defp gre_batch_with_annotation(seat, annotation) do
    %EventRecord{
      id: 99,
      event_type: "GreToClientEvent",
      mtga_timestamp: ~U[2026-04-05 19:18:40Z],
      file_offset: 0,
      source_file: "Player.log",
      raw_json:
        Jason.encode!(%{
          "greToClientEvent" => %{
            "greToClientMessages" => [
              %{
                "type" => "GREMessageType_GameStateMessage",
                "systemSeatIds" => [seat],
                "gameStateMessage" => %{
                  "gameInfo" => %{"matchID" => "match-abc"},
                  "turnInfo" => %{
                    "turnNumber" => 5,
                    "phase" => "Phase_Combat",
                    "activePlayer" => seat
                  },
                  "annotations" => [annotation]
                }
              }
            ]
          }
        }),
      processed: false
    }
  end

  defp gre_batch_with_mulligan_req(seat) do
    %EventRecord{
      id: 99,
      event_type: "GreToClientEvent",
      mtga_timestamp: ~U[2026-04-05 19:18:40Z],
      file_offset: 0,
      source_file: "Player.log",
      raw_json:
        Jason.encode!(%{
          "greToClientEvent" => %{
            "greToClientMessages" => [
              %{
                "type" => "GREMessageType_MulliganReq",
                "systemSeatIds" => [seat],
                "prompt" => %{
                  "parameters" => [%{"parameterName" => "NumberOfCards", "numberValue" => 7}]
                }
              }
            ]
          }
        }),
      processed: false
    }
  end

  defp gre_batch_with_die_roll(seat) do
    other_seat = if seat == 1, do: 2, else: 1

    %EventRecord{
      id: 99,
      event_type: "GreToClientEvent",
      mtga_timestamp: ~U[2026-04-05 19:18:40Z],
      file_offset: 0,
      source_file: "Player.log",
      raw_json:
        Jason.encode!(%{
          "greToClientEvent" => %{
            "greToClientMessages" => [
              %{
                "type" => "GREMessageType_DieRollResultsResp",
                "systemSeatIds" => [seat],
                "dieRollResultsResp" => %{
                  "playerDieRolls" => [
                    %{"systemSeatId" => seat, "rollValue" => 6},
                    %{"systemSeatId" => other_seat, "rollValue" => 3}
                  ]
                }
              }
            ]
          }
        }),
      processed: false
    }
  end
end
