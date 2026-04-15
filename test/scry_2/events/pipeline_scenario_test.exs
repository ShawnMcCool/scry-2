defmodule Scry2.Events.PipelineScenarioTest do
  @moduledoc """
  Scenario integration tests verifying Phase 1 match replay data capture.

  Tests confirm that all new event types introduced in Phase 1 are emitted
  correctly, existing events are unaffected, and the translate pipeline
  produces coherent output across all supported event types.

  All tests are pure function tests: async: true, no DB, no GenServers.
  """
  use ExUnit.Case, async: true

  alias Scry2.Events.IdentifyDomainEvents
  alias Scry2.Events.Combat.{AttackersDeclared, BlockersDeclared}
  alias Scry2.Events.Match.{GameCompleted, MatchCreated}
  alias Scry2.Events.Permanent.{PermanentStatsChanged, PermanentTapped}
  alias Scry2.Events.Priority.{PriorityAssigned, PriorityPassed}
  alias Scry2.Events.Stack.{AbilityActivated, TargetsDeclared, TriggerCreated}
  alias Scry2.Events.Turn.{PhaseChanged, TurnStarted}
  alias Scry2.MtgaLogIngestion.{Event, EventRecord, ExtractEventsFromLog}

  @self_user_id "D0FECB2AF1E7FE24"

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

  defp inline_gre_record(gsm_payload) do
    raw_json =
      Jason.encode!(%{
        "greToClientEvent" => %{
          "greToClientMessages" => [
            Map.merge(
              %{
                "type" => "GREMessageType_GameStateMessage",
                "systemSeatIds" => [1]
              },
              %{"gameStateMessage" => gsm_payload}
            )
          ]
        }
      })

    %EventRecord{
      id: 99,
      event_type: "GreToClientEvent",
      mtga_timestamp: DateTime.utc_now(:second),
      file_offset: 0,
      source_file: "Player.log",
      raw_json: raw_json,
      processed: false
    }
  end

  # ── Turn structure events ────────────────────────────────────────────────

  describe "TurnStarted" do
    test "emitted from real fixture" do
      record = record_from_fixture("gre_game_state_turn_started.log")
      {events, []} = IdentifyDomainEvents.translate(record, @self_user_id, %{})
      assert Enum.any?(events, &match?(%TurnStarted{}, &1))
    end
  end

  describe "PhaseChanged" do
    test "emitted from real fixture" do
      record = record_from_fixture("gre_game_state_turn_started.log")
      {events, []} = IdentifyDomainEvents.translate(record, @self_user_id, %{})
      assert Enum.any?(events, &match?(%PhaseChanged{}, &1))
    end
  end

  # ── Priority events ───────────────────────────────────────────────────────

  describe "PriorityAssigned" do
    test "emitted from real fixture" do
      record = record_from_fixture("gre_game_state_priority_assigned.log")
      {events, []} = IdentifyDomainEvents.translate(record, @self_user_id, %{})
      assert Enum.any?(events, &match?(%PriorityAssigned{}, &1))
    end
  end

  describe "PriorityPassed" do
    test "emitted from real fixture" do
      record = record_from_fixture("client_to_gre_pass_priority.log")

      match_ctx = %{
        current_match_id: "test-match",
        current_game_number: 1,
        turn_phase_state: %{turn: 3, phase: "Phase_Main1", step: nil}
      }

      {events, []} = IdentifyDomainEvents.translate(record, @self_user_id, match_ctx)
      assert Enum.any?(events, &match?(%PriorityPassed{}, &1))
    end
  end

  # ── Stack events ──────────────────────────────────────────────────────────

  describe "TargetsDeclared" do
    test "emitted from AnnotationType_TargetSpec persistent annotation" do
      record =
        inline_gre_record(%{
          "type" => "GameStateType_Diff",
          "turnInfo" => %{"turnNumber" => 5, "phase" => "Phase_Combat"},
          "persistentAnnotations" => [
            %{
              "id" => 10,
              "affectorId" => 500,
              "affectedIds" => [600, 700],
              "type" => ["AnnotationType_TargetSpec"],
              "details" => []
            }
          ]
        })

      {events, []} =
        IdentifyDomainEvents.translate(record, @self_user_id, %{
          game_objects: %{600 => 11111, 700 => 22222}
        })

      td = Enum.find(events, &match?(%TargetsDeclared{}, &1))
      assert td != nil
      assert td.spell_instance_id == 500
      assert length(td.targets) == 2
      assert Enum.find(td.targets, &(&1.instance_id == 600 and &1.arena_id == 11111))
      assert Enum.find(td.targets, &(&1.instance_id == 700 and &1.arena_id == 22222))
    end
  end

  describe "AbilityActivated" do
    test "emitted from AnnotationType_ActivatedAbility annotation" do
      record =
        inline_gre_record(%{
          "type" => "GameStateType_Diff",
          "turnInfo" => %{"turnNumber" => 3, "phase" => "Phase_Main1"},
          "annotations" => [
            %{
              "id" => 20,
              "affectorId" => 42,
              "affectedIds" => [42],
              "type" => ["AnnotationType_ActivatedAbility"]
            }
          ]
        })

      {events, []} =
        IdentifyDomainEvents.translate(record, @self_user_id, %{game_objects: %{42 => 99999}})

      aa = Enum.find(events, &match?(%AbilityActivated{}, &1))
      assert aa != nil
      assert aa.source_instance_id == 42
      assert aa.source_arena_id == 99999
    end
  end

  describe "TriggerCreated" do
    test "emitted from AnnotationType_TriggeredAbility annotation" do
      record =
        inline_gre_record(%{
          "type" => "GameStateType_Diff",
          "turnInfo" => %{"turnNumber" => 2, "phase" => "Phase_Beginning"},
          "annotations" => [
            %{
              "id" => 30,
              "affectorId" => 77,
              "affectedIds" => [77],
              "type" => ["AnnotationType_TriggeredAbility"],
              "details" => []
            }
          ]
        })

      {events, []} =
        IdentifyDomainEvents.translate(record, @self_user_id, %{game_objects: %{}})

      tc = Enum.find(events, &match?(%TriggerCreated{}, &1))
      assert tc != nil
      assert tc.source_instance_id == 77
    end
  end

  # ── Combat events ──────────────────────────────────────────────────────────

  describe "AttackersDeclared" do
    test "emitted from real fixture" do
      record = record_from_fixture("client_to_gre_declare_attackers.log")

      match_ctx = %{
        current_match_id: "test-match",
        current_game_number: 1,
        game_objects: %{},
        turn_phase_state: %{turn: 5}
      }

      {events, []} = IdentifyDomainEvents.translate(record, @self_user_id, match_ctx)
      assert Enum.any?(events, &match?(%AttackersDeclared{}, &1))
    end
  end

  describe "BlockersDeclared" do
    test "emitted from real fixture" do
      record = record_from_fixture("client_to_gre_declare_blockers.log")

      match_ctx = %{
        current_match_id: "test-match",
        current_game_number: 1,
        game_objects: %{853 => 12345},
        turn_phase_state: %{turn: 8}
      }

      {events, []} = IdentifyDomainEvents.translate(record, @self_user_id, match_ctx)
      assert Enum.any?(events, &match?(%BlockersDeclared{}, &1))
    end
  end

  # ── Permanent state events ────────────────────────────────────────────────

  describe "PermanentTapped" do
    test "emitted from real fixture" do
      record = record_from_fixture("gre_game_state_permanent_tap.log")

      {events, []} =
        IdentifyDomainEvents.translate(record, @self_user_id, %{game_object_states: %{}})

      assert Enum.any?(events, &match?(%PermanentTapped{}, &1))
    end
  end

  describe "PermanentStatsChanged" do
    test "emitted from real fixture" do
      record = record_from_fixture("gre_game_state_stats_changed.log")

      {events, []} =
        IdentifyDomainEvents.translate(record, @self_user_id, %{game_object_states: %{}})

      assert Enum.any?(events, &match?(%PermanentStatsChanged{}, &1))
    end
  end

  # ── Existing events unaffected ─────────────────────────────────────────────

  describe "existing events unaffected" do
    test "GameCompleted still emitted from game complete fixture" do
      record = record_from_fixture("gre_to_client_event_game_complete.log")
      {events, []} = IdentifyDomainEvents.translate(record, @self_user_id, %{})

      assert Enum.any?(events, &match?(%GameCompleted{}, &1)),
             "GameCompleted must still be emitted: got #{inspect(Enum.map(events, & &1.__struct__))}"
    end

    test "MatchCreated still emitted from match playing fixture" do
      record = record_from_fixture("match_game_room_state_changed_playing.log")
      {events, []} = IdentifyDomainEvents.translate(record, @self_user_id, %{})

      assert Enum.any?(events, &match?(%MatchCreated{}, &1)),
             "MatchCreated must still be emitted"
    end
  end

  # ── Context accumulation ──────────────────────────────────────────────────

  describe "context accumulation" do
    test "turn_phase_state suppresses duplicate TurnStarted across consecutive translate calls" do
      record = record_from_fixture("gre_game_state_turn_started.log")

      # First call with empty context — TurnStarted fires
      {events_first, []} = IdentifyDomainEvents.translate(record, @self_user_id, %{})
      first_turn = Enum.find(events_first, &match?(%TurnStarted{}, &1))
      assert first_turn != nil

      # Second call with the turn already in context — no TurnStarted
      context = %{turn_phase_state: %{turn: first_turn.turn_number}}
      {events_second, []} = IdentifyDomainEvents.translate(record, @self_user_id, context)

      refute Enum.any?(events_second, &match?(%TurnStarted{}, &1)),
             "TurnStarted must not fire again when turn is unchanged"
    end
  end
end
