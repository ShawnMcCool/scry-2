defmodule Scry2.Events.IdentifyDomainEvents.MatchRoomTest do
  @moduledoc """
  Direct tests for the MatchGameRoomStateChangedEvent translator.

  The high-level coordinator (`Scry2.Events.IdentifyDomainEvents`) is already
  exercised by `IdentifyDomainEventsTest` against real captured fixtures.
  These tests pin down the helper-level branches that are easier to verify
  in isolation: missing fields, malformed payloads, and the concession path
  where the opponent wins the match.
  """
  use ExUnit.Case, async: true

  alias Scry2.Events.IdentifyDomainEvents.MatchRoom
  alias Scry2.Events.Match.{MatchCompleted, MatchCreated}
  alias Scry2.Events.TranslationWarning
  alias Scry2.MtgaLogIngestion.EventRecord

  @self_user_id "SELF_USER_ID"

  defp build_record(payload) do
    %EventRecord{
      id: 1,
      event_type: "MatchGameRoomStateChangedEvent",
      mtga_timestamp: ~U[2026-05-01 12:00:00Z],
      file_offset: 0,
      source_file: "Player.log",
      raw_json: Jason.encode!(payload),
      processed: false
    }
  end

  defp playing_payload(reserved, match_id \\ "match-1") do
    %{
      "matchGameRoomStateChangedEvent" => %{
        "gameRoomInfo" => %{
          "gameRoomConfig" => %{
            "matchId" => match_id,
            "reservedPlayers" => reserved
          },
          "stateType" => "MatchGameRoomStateType_Playing"
        }
      }
    }
  end

  defp completed_payload(reserved, result_list, match_id \\ "match-1") do
    %{
      "matchGameRoomStateChangedEvent" => %{
        "gameRoomInfo" => %{
          "gameRoomConfig" => %{
            "matchId" => match_id,
            "reservedPlayers" => reserved
          },
          "stateType" => "MatchGameRoomStateType_MatchCompleted",
          "finalMatchResult" => %{
            "matchCompletedReason" => "MatchCompletedReasonType_Success",
            "resultList" => result_list
          }
        }
      }
    }
  end

  describe "translate/3 — Playing state" do
    test "emits %MatchCreated{} with opponent identified by userId" do
      record =
        build_record(
          playing_payload([
            %{
              "userId" => @self_user_id,
              "playerName" => "Self",
              "systemSeatId" => 1,
              "platformId" => "SteamWindows",
              "eventId" => "Traditional_Ladder"
            },
            %{
              "userId" => "OPP",
              "playerName" => "Opp",
              "systemSeatId" => 2,
              "platformId" => "Windows"
            }
          ])
        )

      assert {[%MatchCreated{} = event], []} = MatchRoom.translate(record, @self_user_id, %{})
      assert event.mtga_match_id == "match-1"
      assert event.opponent_user_id == "OPP"
      assert event.opponent_screen_name == "Opp"
      assert event.platform == "SteamWindows"
      assert event.opponent_platform == "Windows"
      assert event.event_name == "Traditional_Ladder"
      assert event.opponent_rank_class == nil
      assert event.opponent_rank_tier == nil
    end

    test "falls back to systemSeatId != 1 for opponent when self_user_id is nil" do
      record =
        build_record(
          playing_payload([
            %{"playerName" => "Self", "systemSeatId" => 1, "eventId" => "QuickDraft_FDN"},
            %{"playerName" => "Opp", "systemSeatId" => 2}
          ])
        )

      assert {[%MatchCreated{} = event], []} = MatchRoom.translate(record, nil, %{})
      assert event.opponent_screen_name == "Opp"
      assert event.event_name == "QuickDraft_FDN"
    end

    test "returns [] when matchId is missing" do
      payload = %{
        "matchGameRoomStateChangedEvent" => %{
          "gameRoomInfo" => %{
            "gameRoomConfig" => %{"reservedPlayers" => []},
            "stateType" => "MatchGameRoomStateType_Playing"
          }
        }
      }

      record = build_record(payload)
      assert {[], []} = MatchRoom.translate(record, @self_user_id, %{})
    end

    test "returns [] when matchId is the empty string" do
      record = build_record(playing_payload([], ""))
      assert {[], []} = MatchRoom.translate(record, @self_user_id, %{})
    end

    test "carries opponent rank fields if MTGA ever populates playerRankInfo" do
      record =
        build_record(
          playing_payload([
            %{"userId" => @self_user_id, "systemSeatId" => 1},
            %{
              "userId" => "OPP",
              "systemSeatId" => 2,
              "playerRankInfo" => %{
                "rankClass" => "Gold",
                "rankTier" => 2,
                "leaderboardPercentile" => 5.5,
                "leaderboardPlacement" => 100
              }
            }
          ])
        )

      assert {[%MatchCreated{} = event], []} = MatchRoom.translate(record, @self_user_id, %{})
      assert event.opponent_rank_class == "Gold"
      assert event.opponent_rank_tier == 2
      assert event.opponent_leaderboard_percentile == 5.5
      assert event.opponent_leaderboard_placement == 100
    end
  end

  describe "translate/3 — MatchCompleted state" do
    test "won=true when MatchScope_Match winningTeamId == self team" do
      record =
        build_record(
          completed_payload(
            [
              %{"userId" => @self_user_id, "systemSeatId" => 1, "teamId" => 1},
              %{"userId" => "OPP", "systemSeatId" => 2, "teamId" => 2}
            ],
            [
              %{"scope" => "MatchScope_Game", "winningTeamId" => 1, "reason" => "Concede"},
              %{"scope" => "MatchScope_Match", "winningTeamId" => 1, "reason" => "Concede"}
            ]
          )
        )

      assert {[%MatchCompleted{} = event], []} = MatchRoom.translate(record, @self_user_id, %{})
      assert event.won == true
      assert event.num_games == 1
      assert event.reason == "MatchCompletedReasonType_Success"
      assert length(event.game_results) == 1
    end

    test "won=false when self conceded — opponent's winningTeamId wins MatchScope_Match" do
      record =
        build_record(
          completed_payload(
            [
              %{"userId" => @self_user_id, "systemSeatId" => 1, "teamId" => 1},
              %{"userId" => "OPP", "systemSeatId" => 2, "teamId" => 2}
            ],
            [
              %{"scope" => "MatchScope_Game", "winningTeamId" => 2, "reason" => "Concede"},
              %{"scope" => "MatchScope_Game", "winningTeamId" => 2, "reason" => "Concede"},
              %{"scope" => "MatchScope_Match", "winningTeamId" => 2, "reason" => "Concede"}
            ]
          )
        )

      assert {[%MatchCompleted{} = event], []} = MatchRoom.translate(record, @self_user_id, %{})
      assert event.won == false
      assert event.num_games == 2
      assert Enum.all?(event.game_results, fn row -> row.won == false end)
    end

    test "returns [] when reservedPlayers does not include self" do
      record =
        build_record(
          completed_payload(
            [
              %{"userId" => "STRANGER", "systemSeatId" => 1, "teamId" => 1}
            ],
            [%{"scope" => "MatchScope_Match", "winningTeamId" => 1}]
          )
        )

      assert {[], []} = MatchRoom.translate(record, @self_user_id, %{})
    end

    test "returns [] when no MatchScope_Match row exists" do
      record =
        build_record(
          completed_payload(
            [%{"userId" => @self_user_id, "systemSeatId" => 1, "teamId" => 1}],
            [%{"scope" => "MatchScope_Game", "winningTeamId" => 1, "reason" => "Concede"}]
          )
        )

      assert {[], []} = MatchRoom.translate(record, @self_user_id, %{})
    end

    test "game_results carries each MatchScope_Game row in order with self perspective" do
      record =
        build_record(
          completed_payload(
            [
              %{"userId" => @self_user_id, "systemSeatId" => 1, "teamId" => 1},
              %{"userId" => "OPP", "systemSeatId" => 2, "teamId" => 2}
            ],
            [
              %{"scope" => "MatchScope_Game", "winningTeamId" => 2, "reason" => "Concede"},
              %{"scope" => "MatchScope_Game", "winningTeamId" => 1, "reason" => "Concede"},
              %{"scope" => "MatchScope_Game", "winningTeamId" => 1, "reason" => "Concede"},
              %{"scope" => "MatchScope_Match", "winningTeamId" => 1, "reason" => "Concede"}
            ]
          )
        )

      assert {[%MatchCompleted{} = event], []} = MatchRoom.translate(record, @self_user_id, %{})

      assert event.game_results == [
               %{game_number: 1, winning_team_id: 2, won: false, reason: "Concede"},
               %{game_number: 2, winning_team_id: 1, won: true, reason: "Concede"},
               %{game_number: 3, winning_team_id: 1, won: true, reason: "Concede"}
             ]
    end
  end

  describe "translate/3 — non-handled and malformed payloads" do
    test "non-Playing/Completed stateType returns []" do
      payload = %{
        "matchGameRoomStateChangedEvent" => %{
          "gameRoomInfo" => %{
            "gameRoomConfig" => %{"matchId" => "match-1", "reservedPlayers" => []},
            "stateType" => "MatchGameRoomStateType_Closed"
          }
        }
      }

      record = build_record(payload)
      assert {[], []} = MatchRoom.translate(record, @self_user_id, %{})
    end

    test "malformed JSON yields a TranslationWarning" do
      record = %EventRecord{
        id: 7,
        event_type: "MatchGameRoomStateChangedEvent",
        mtga_timestamp: ~U[2026-05-01 12:00:00Z],
        file_offset: 0,
        source_file: "Player.log",
        raw_json: "not valid json",
        processed: false
      }

      assert {[], [%TranslationWarning{} = warning]} =
               MatchRoom.translate(record, @self_user_id, %{})

      assert warning.category == :payload_extraction_failed
      assert warning.event_type == "MatchGameRoomStateChangedEvent"
      assert warning.raw_event_id == 7
    end

    test "missing gameRoomInfo yields a TranslationWarning" do
      record = build_record(%{"matchGameRoomStateChangedEvent" => %{}})

      assert {[], [%TranslationWarning{} = warning]} =
               MatchRoom.translate(record, @self_user_id, %{})

      assert warning.category == :payload_extraction_failed
    end
  end
end
