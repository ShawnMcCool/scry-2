defmodule Scry2.EventsTest do
  use Scry2.DataCase

  alias Scry2.Events
  alias Scry2.Events.{EventRecord, MatchCreated, MatchCompleted}
  alias Scry2.TestFactory
  alias Scry2.Topics

  describe "append!/2" do
    test "persists a MatchCreated and broadcasts {:domain_event, id, slug}" do
      Topics.subscribe(Topics.domain_events())

      source = TestFactory.create_event_record(%{event_type: "MatchGameRoomStateChangedEvent"})

      event = %MatchCreated{
        mtga_match_id: "m-1",
        event_name: "Traditional_Ladder",
        opponent_screen_name: "Opponent1",
        occurred_at: ~U[2026-04-05 19:18:40Z]
      }

      record = Events.append!(event, source)

      assert %EventRecord{event_type: "match_created"} = record
      assert record.mtga_source_id == source.id
      assert record.mtga_timestamp == ~U[2026-04-05 19:18:40Z]
      assert record.payload["mtga_match_id"] == "m-1"
      assert record.payload["event_name"] == "Traditional_Ladder"
      assert record.payload["occurred_at"] == "2026-04-05T19:18:40Z"

      assert_receive {:domain_event, id, "match_created"}
      assert id == record.id
    end

    test "accepts nil source_record for synthetic events" do
      event = %MatchCreated{
        mtga_match_id: "m-2",
        event_name: "Test",
        occurred_at: ~U[2026-04-05 12:00:00Z]
      }

      record = Events.append!(event, nil)
      assert record.mtga_source_id == nil
    end

    test "persists a MatchCompleted with won/num_games fields" do
      event = %MatchCompleted{
        mtga_match_id: "m-3",
        occurred_at: ~U[2026-04-05 19:53:36Z],
        won: true,
        num_games: 3,
        reason: "MatchCompletedReasonType_Success"
      }

      record = Events.append!(event, nil)
      assert record.event_type == "match_completed"
      assert record.payload["won"] == true
      assert record.payload["num_games"] == 3
      assert record.payload["reason"] == "MatchCompletedReasonType_Success"
    end
  end

  describe "get/1 and get!/1 — rehydration" do
    test "round-trips a MatchCreated back to the struct form" do
      original = %MatchCreated{
        mtga_match_id: "m-round-1",
        event_name: "Traditional_Ladder",
        opponent_screen_name: "Opponent1",
        occurred_at: ~U[2026-04-05 19:18:40Z]
      }

      record = Events.append!(original, nil)

      assert {:ok, %MatchCreated{} = rehydrated} = Events.get(record.id)
      assert rehydrated.mtga_match_id == original.mtga_match_id
      assert rehydrated.event_name == original.event_name
      assert rehydrated.opponent_screen_name == original.opponent_screen_name
      assert rehydrated.occurred_at == original.occurred_at
    end

    test "round-trips a MatchCompleted" do
      original = %MatchCompleted{
        mtga_match_id: "m-round-2",
        occurred_at: ~U[2026-04-05 19:53:36Z],
        won: false,
        num_games: 2,
        reason: "MatchCompletedReasonType_TimeOut"
      }

      record = Events.append!(original, nil)

      assert %MatchCompleted{} = rehydrated = Events.get!(record.id)
      assert rehydrated.mtga_match_id == original.mtga_match_id
      assert rehydrated.occurred_at == original.occurred_at
      assert rehydrated.won == false
      assert rehydrated.num_games == 2
      assert rehydrated.reason == "MatchCompletedReasonType_TimeOut"
    end

    test "get/1 returns {:error, :not_found} for missing id" do
      assert Events.get(-1) == {:error, :not_found}
    end
  end

  describe "list_since/1" do
    test "returns events with id greater than since_id, ordered ascending" do
      a = Events.append!(match_created("a"), nil)
      b = Events.append!(match_created("b"), nil)
      c = Events.append!(match_created("c"), nil)

      assert Enum.map(Events.list_since(0), & &1.id) == [a.id, b.id, c.id]
      assert Enum.map(Events.list_since(a.id), & &1.id) == [b.id, c.id]
      assert Events.list_since(c.id) == []
    end
  end

  describe "count_by_type/0" do
    test "returns a slug → count map" do
      Events.append!(match_created("a"), nil)
      Events.append!(match_created("b"), nil)
      Events.append!(match_completed("a"), nil)

      counts = Events.count_by_type()
      assert counts["match_created"] == 2
      assert counts["match_completed"] == 1
    end
  end

  describe "subscribe/0" do
    test "subscribes the caller to domain_events topic" do
      :ok = Events.subscribe()

      event = match_created("sub-test")
      record = Events.append!(event, nil)

      assert_receive {:domain_event, id, "match_created"}
      assert id == record.id
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────

  defp match_created(match_id) do
    %MatchCreated{
      mtga_match_id: match_id,
      event_name: "Traditional_Ladder",
      opponent_screen_name: "Opponent1",
      occurred_at: ~U[2026-04-05 19:18:40Z]
    }
  end

  defp match_completed(match_id) do
    %MatchCompleted{
      mtga_match_id: match_id,
      occurred_at: ~U[2026-04-05 19:53:36Z],
      won: true,
      num_games: 2
    }
  end
end
