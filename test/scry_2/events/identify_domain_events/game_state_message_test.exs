defmodule Scry2.Events.IdentifyDomainEvents.GameStateMessageTest do
  use ExUnit.Case, async: true

  alias Scry2.Events.IdentifyDomainEvents
  alias Scry2.Events.Turn.{TurnStarted, PhaseChanged}
  alias Scry2.MtgaLogIngestion.{Event, EventRecord, ExtractEventsFromLog}

  @self_user_id "D0FECB2AF1E7FE24"

  defp record_from_fixture(fixture_name) do
    path = Path.join([__DIR__, "..", "..", "..", "fixtures", "mtga_logs", fixture_name])
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

  describe "TurnStarted" do
    test "emits TurnStarted when turn number changes from nil (first turn)" do
      record = record_from_fixture("gre_game_state_turn_started.log")
      {events, []} = IdentifyDomainEvents.translate(record, @self_user_id, %{})

      assert Enum.any?(events, &match?(%TurnStarted{}, &1)),
             "Expected TurnStarted, got: #{inspect(Enum.map(events, & &1.__struct__))}"

      turn_event = Enum.find(events, &match?(%TurnStarted{}, &1))
      assert is_integer(turn_event.turn_number) and turn_event.turn_number > 0
      assert is_integer(turn_event.active_player_seat)
    end

    test "does NOT emit TurnStarted when turn number is unchanged" do
      record = record_from_fixture("gre_game_state_turn_started.log")
      {events_first, []} = IdentifyDomainEvents.translate(record, @self_user_id, %{})
      first_turn = Enum.find(events_first, &match?(%TurnStarted{}, &1))

      # Same turn in context → no new TurnStarted
      context = %{turn_phase_state: %{turn: first_turn.turn_number}}
      {events_second, []} = IdentifyDomainEvents.translate(record, @self_user_id, context)

      refute Enum.any?(events_second, &match?(%TurnStarted{}, &1)),
             "Should not emit TurnStarted when turn is unchanged"
    end
  end

  describe "turn structure suppression" do
    test "does NOT emit TurnStarted or PhaseChanged when batch has no turnInfo" do
      raw_json =
        Jason.encode!(%{
          "greToClientEvent" => %{
            "greToClientMessages" => [
              %{
                "type" => "GREMessageType_GameStateMessage",
                "systemSeatIds" => [1],
                "gameStateMessage" => %{
                  "type" => "GameStateType_Diff",
                  "gameObjects" => []
                  # No turnInfo key
                }
              }
            ]
          }
        })

      record = %Scry2.MtgaLogIngestion.EventRecord{
        id: 1,
        event_type: "GreToClientEvent",
        mtga_timestamp: DateTime.utc_now(:second),
        file_offset: 0,
        source_file: "Player.log",
        raw_json: raw_json,
        processed: false
      }

      {events, _} = IdentifyDomainEvents.translate(record, @self_user_id, %{})

      refute Enum.any?(events, &match?(%TurnStarted{}, &1)),
             "Should not emit TurnStarted when no turnInfo present"

      refute Enum.any?(events, &match?(%PhaseChanged{}, &1)),
             "Should not emit PhaseChanged when no turnInfo present"
    end

    test "re-emits PhaseChanged after TurnStarted resets phase to nil" do
      record = record_from_fixture("gre_game_state_turn_started.log")
      {events_first, []} = IdentifyDomainEvents.translate(record, @self_user_id, %{})
      first_turn = Enum.find(events_first, &match?(%TurnStarted{}, &1))

      # Simulate state after TurnStarted fired: phase reset to nil for the new turn
      post_turn_context = %{
        turn_phase_state: %{turn: first_turn.turn_number + 1, phase: nil, step: nil}
      }

      # Same fixture with a context where the turn advanced but phase was reset.
      # The fixture has a phase — PhaseChanged should re-emit because context phase is nil.
      {events_second, []} =
        IdentifyDomainEvents.translate(record, @self_user_id, post_turn_context)

      assert Enum.any?(events_second, &match?(%PhaseChanged{}, &1)),
             "Should emit PhaseChanged when context phase is nil (after turn boundary reset)"
    end
  end

  describe "PriorityAssigned" do
    test "emits PriorityAssigned for each GameStateMessage with priorityPlayer" do
      record = record_from_fixture("gre_game_state_priority_assigned.log")
      {events, []} = IdentifyDomainEvents.translate(record, @self_user_id, %{})

      priority_events =
        Enum.filter(events, &match?(%Scry2.Events.Priority.PriorityAssigned{}, &1))

      # No delta detection — every priority assignment emits an event
      assert length(priority_events) >= 1,
             "Expected at least one PriorityAssigned per GSM message with priorityPlayer"

      # All events have a valid player seat
      assert Enum.all?(priority_events, fn pa -> is_integer(pa.player_seat) end)
    end
  end

  describe "PermanentTapped" do
    test "emits PermanentTapped when a game object is tapped and was not tapped before" do
      record = record_from_fixture("gre_game_state_permanent_tap.log")
      # Empty prior state → all tapped objects are "newly tapped"
      {events, []} =
        IdentifyDomainEvents.translate(record, @self_user_id, %{game_object_states: %{}})

      tapped = Enum.filter(events, &match?(%Scry2.Events.Permanent.PermanentTapped{}, &1))
      assert tapped != [], "Expected at least one PermanentTapped event"
      assert Enum.all?(tapped, fn e -> is_integer(e.instance_id) end)
    end

    test "does NOT emit PermanentTapped when object was already tapped in context" do
      record = record_from_fixture("gre_game_state_permanent_tap.log")

      {events_first, []} =
        IdentifyDomainEvents.translate(record, @self_user_id, %{game_object_states: %{}})

      first_tapped =
        Enum.find(events_first, &match?(%Scry2.Events.Permanent.PermanentTapped{}, &1))

      assert first_tapped != nil, "Prerequisite: fixture must have a tapped object"

      # Mark object as already tapped in context
      prior_states = %{first_tapped.instance_id => %{tapped: true, power: nil, toughness: nil}}

      {events_second, []} =
        IdentifyDomainEvents.translate(record, @self_user_id, %{game_object_states: prior_states})

      tapped_instance_id = first_tapped.instance_id

      refute Enum.any?(events_second, fn e ->
               match?(
                 %Scry2.Events.Permanent.PermanentTapped{instance_id: ^tapped_instance_id},
                 e
               )
             end),
             "Should not emit PermanentTapped for already-tapped object"
    end
  end

  describe "PermanentStatsChanged" do
    test "emits PermanentStatsChanged when power/toughness changes from nil" do
      record = record_from_fixture("gre_game_state_stats_changed.log")

      {events, []} =
        IdentifyDomainEvents.translate(record, @self_user_id, %{game_object_states: %{}})

      stats_events =
        Enum.filter(events, &match?(%Scry2.Events.Permanent.PermanentStatsChanged{}, &1))

      assert stats_events != [], "Expected at least one PermanentStatsChanged event"

      stat = hd(stats_events)
      assert is_integer(stat.instance_id)
      # power and toughness should be integers, not nested maps
      assert is_integer(stat.power) or is_nil(stat.power)
      assert is_integer(stat.toughness) or is_nil(stat.toughness)
    end

    test "does NOT emit PermanentStatsChanged when stats are unchanged" do
      record = record_from_fixture("gre_game_state_stats_changed.log")

      {events_first, []} =
        IdentifyDomainEvents.translate(record, @self_user_id, %{game_object_states: %{}})

      first_stats =
        Enum.find(events_first, &match?(%Scry2.Events.Permanent.PermanentStatsChanged{}, &1))

      if first_stats do
        stats_instance_id = first_stats.instance_id

        prior_states = %{
          stats_instance_id => %{
            tapped: false,
            power: first_stats.power,
            toughness: first_stats.toughness
          }
        }

        {events_second, []} =
          IdentifyDomainEvents.translate(record, @self_user_id, %{
            game_object_states: prior_states
          })

        refute Enum.any?(events_second, fn e ->
                 match?(
                   %Scry2.Events.Permanent.PermanentStatsChanged{
                     instance_id: ^stats_instance_id
                   },
                   e
                 )
               end),
               "Should not emit PermanentStatsChanged when stats unchanged"
      end
    end
  end

  describe "PhaseChanged" do
    test "emits PhaseChanged when phase changes from nil (first message)" do
      record = record_from_fixture("gre_game_state_turn_started.log")
      {events, []} = IdentifyDomainEvents.translate(record, @self_user_id, %{})

      assert Enum.any?(events, &match?(%PhaseChanged{}, &1)),
             "Expected PhaseChanged, got: #{inspect(Enum.map(events, & &1.__struct__))}"

      phase_event = Enum.find(events, &match?(%PhaseChanged{}, &1))
      assert is_binary(phase_event.phase) and phase_event.phase != ""
    end

    test "does NOT emit PhaseChanged when phase is unchanged" do
      record = record_from_fixture("gre_game_state_turn_started.log")
      {events_first, []} = IdentifyDomainEvents.translate(record, @self_user_id, %{})
      first_phase = Enum.find(events_first, &match?(%PhaseChanged{}, &1))

      context = %{
        turn_phase_state: %{
          turn: first_phase.turn_number,
          phase: first_phase.phase,
          step: first_phase.step
        }
      }

      {events_second, []} = IdentifyDomainEvents.translate(record, @self_user_id, context)

      refute Enum.any?(events_second, &match?(%PhaseChanged{}, &1)),
             "Should not emit PhaseChanged when phase is unchanged"
    end

    test "PhaseChanged carries turn_number from turnInfo" do
      record = record_from_fixture("gre_game_state_turn_started.log")
      {events, []} = IdentifyDomainEvents.translate(record, @self_user_id, %{})

      phase_event = Enum.find(events, &match?(%PhaseChanged{}, &1))
      assert is_integer(phase_event.turn_number)
    end
  end
end
