defmodule Scry2.Events.MatchCompletedTest do
  use ExUnit.Case, async: true

  alias Scry2.Events.Event
  alias Scry2.Events.Match.MatchCompleted

  describe "struct construction" do
    test "builds a valid MatchCompleted" do
      event = %MatchCompleted{
        mtga_match_id: "m-1",
        occurred_at: ~U[2026-04-05 19:53:36Z],
        won: true,
        num_games: 3,
        reason: "MatchCompletedReasonType_Success"
      }

      assert event.mtga_match_id == "m-1"
      assert event.won == true
      assert event.num_games == 3
      assert event.reason == "MatchCompletedReasonType_Success"
    end

    test "enforces required keys" do
      assert_raise ArgumentError, fn ->
        struct!(MatchCompleted, %{won: true})
      end
    end
  end

  describe "Scry2.Events.Event protocol" do
    test "type_slug returns 'match_completed'" do
      event = %MatchCompleted{
        mtga_match_id: "x",
        occurred_at: DateTime.utc_now(),
        won: true,
        num_games: 2
      }

      assert Event.type_slug(event) == "match_completed"
    end

    test "mtga_timestamp returns the occurred_at value" do
      ts = ~U[2026-04-05 19:53:36Z]

      event = %MatchCompleted{
        mtga_match_id: "x",
        occurred_at: ts,
        won: false,
        num_games: 3
      }

      assert Event.mtga_timestamp(event) == ts
    end
  end
end
