defmodule Scry2.Events.IdentifyDomainEventsTest do
  use ExUnit.Case, async: true

  alias Scry2.Events.Deck.{DeckInventory, DeckSelected, DeckSubmitted, DeckUpdated}

  alias Scry2.Events.Draft.{
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
  alias Scry2.Events.Session.SessionStarted
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

  describe "translate/3 — GreToClientEvent with match context map" do
    test "uses current_match_id from match context when event has no match id" do
      record = record_from_fixture("gre_to_client_event_connect_resp.log")

      # IngestRawEvents converts IngestionState.Match to a plain map before
      # calling translate/3, so match_context is always an atom-keyed map.
      match_context = %{
        current_match_id: "008b1926-09a8-40b4-872d-fa987588740c",
        last_hand_game_objects: %{}
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
      assert inv.vault_progress == 150
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
      assert event.format == "DirectGameLimited"
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
      assert event.vault_progress == 475
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
  end
end
