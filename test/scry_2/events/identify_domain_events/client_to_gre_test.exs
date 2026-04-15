defmodule Scry2.Events.IdentifyDomainEvents.ClientToGreTest do
  use ExUnit.Case, async: true

  alias Scry2.Events.IdentifyDomainEvents
  alias Scry2.Events.Priority.PriorityPassed
  alias Scry2.MtgaLogIngestion.{Event, EventRecord, ExtractEventsFromLog}

  @self_user_id "test-user-id"

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

  describe "PriorityPassed" do
    test "emits PriorityPassed when all actions are ActionType_Pass" do
      record = record_from_fixture("client_to_gre_pass_priority.log")

      match_ctx = %{
        current_match_id: "test-match-id",
        current_game_number: 1,
        turn_phase_state: %{turn: 3, phase: "Phase_Main1", step: nil}
      }

      {events, []} = IdentifyDomainEvents.translate(record, @self_user_id, match_ctx)

      assert Enum.any?(events, &match?(%PriorityPassed{}, &1)),
             "Expected PriorityPassed, got: #{inspect(Enum.map(events, & &1.__struct__))}"

      pp = Enum.find(events, &match?(%PriorityPassed{}, &1))
      assert pp.turn_number == 3
      assert pp.phase == "Phase_Main1"
    end

    test "does NOT emit PriorityPassed when actions include ActionType_Play (land play)" do
      record = record_from_fixture("client_to_gre_land_play.log")

      match_ctx = %{
        current_match_id: "test-match-id",
        current_game_number: 1,
        turn_phase_state: %{turn: 1, phase: "Phase_Main1", step: nil}
      }

      {events, []} = IdentifyDomainEvents.translate(record, @self_user_id, match_ctx)

      refute Enum.any?(events, &match?(%PriorityPassed{}, &1)),
             "Should NOT emit PriorityPassed for ActionType_Play (land play)"
    end
  end
end
