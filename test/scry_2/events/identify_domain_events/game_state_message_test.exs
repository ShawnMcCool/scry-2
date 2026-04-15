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
