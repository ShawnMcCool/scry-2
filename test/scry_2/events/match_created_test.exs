defmodule Scry2.Events.MatchCreatedTest do
  use ExUnit.Case, async: true

  alias Scry2.Events.Event
  alias Scry2.Events.MatchCreated

  describe "struct construction" do
    test "builds a valid MatchCreated" do
      event = %MatchCreated{
        mtga_match_id: "m-1",
        event_name: "Traditional_Ladder",
        opponent_screen_name: "Opponent1",
        started_at: ~U[2026-04-05 19:18:40Z]
      }

      assert event.mtga_match_id == "m-1"
      assert event.event_name == "Traditional_Ladder"
      assert event.opponent_screen_name == "Opponent1"
      assert event.started_at == ~U[2026-04-05 19:18:40Z]
    end

    test "raises KeyError when required keys are missing" do
      assert_raise ArgumentError, fn ->
        struct!(MatchCreated, %{event_name: "only"})
      end
    end

    test "allows nil for optional fields" do
      event = %MatchCreated{
        mtga_match_id: "m-2",
        started_at: DateTime.utc_now(),
        event_name: nil,
        opponent_screen_name: nil
      }

      assert event.event_name == nil
      assert event.opponent_screen_name == nil
    end
  end

  describe "Scry2.Events.Event protocol" do
    test "type_slug returns 'match_created'" do
      event = %MatchCreated{mtga_match_id: "x", started_at: DateTime.utc_now()}
      assert Event.type_slug(event) == "match_created"
    end

    test "mtga_timestamp returns the started_at value" do
      ts = ~U[2026-04-05 19:18:40Z]
      event = %MatchCreated{mtga_match_id: "x", started_at: ts}
      assert Event.mtga_timestamp(event) == ts
    end
  end
end
