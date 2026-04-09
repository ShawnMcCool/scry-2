defmodule Scry2.EventsTest do
  use Scry2.DataCase

  alias Scry2.Events
  alias Scry2.Events.EventRecord
  alias Scry2.Events.Match.{MatchCompleted, MatchCreated}
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

  describe "append!/2 — idempotency (ADR-016)" do
    test "duplicate domain event from same source is silently skipped" do
      Topics.subscribe(Topics.domain_events())

      source = TestFactory.create_event_record(%{event_type: "MatchGameRoomStateChangedEvent"})

      event = %MatchCreated{
        mtga_match_id: "dedup-1",
        event_name: "Traditional_Ladder",
        occurred_at: ~U[2026-04-05 19:18:40Z]
      }

      first = Events.append!(event, source)
      assert first != nil
      assert_receive {:domain_event, _, "match_created"}

      second = Events.append!(event, source)
      assert second == nil
      refute_receive {:domain_event, _, _}
    end

    test "different event types from same source both persist" do
      source = TestFactory.create_event_record(%{event_type: "GreToClientEvent"})

      created = %MatchCreated{
        mtga_match_id: "multi-1",
        event_name: "Test",
        occurred_at: ~U[2026-04-05 12:00:00Z]
      }

      completed = %MatchCompleted{
        mtga_match_id: "multi-1",
        occurred_at: ~U[2026-04-05 12:30:00Z],
        won: true,
        num_games: 2
      }

      assert Events.append!(created, source) != nil
      assert Events.append!(completed, source) != nil
    end

    test "multiple same-type events from same source get sequential sequence numbers" do
      source = TestFactory.create_event_record(%{event_type: "GreToClientEvent"})

      event_a = %Events.Gameplay.MulliganOffered{
        mtga_match_id: "seq-1",
        seat_id: 1,
        hand_size: 7,
        occurred_at: ~U[2026-04-05 12:00:00Z]
      }

      event_b = %Events.Gameplay.MulliganOffered{
        mtga_match_id: "seq-1",
        seat_id: 2,
        hand_size: 7,
        occurred_at: ~U[2026-04-05 12:00:01Z]
      }

      first = Events.append!(event_a, source, sequence: 0)
      second = Events.append!(event_b, source, sequence: 1)

      assert first != nil
      assert second != nil
      assert first.sequence == 0
      assert second.sequence == 1
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

  describe "replay_by_types/3" do
    test "returns events in strict id order across multiple type slugs" do
      a = Events.append!(match_created("r1"), nil)
      b = Events.append!(match_completed("r1"), nil)
      c = Events.append!(match_created("r2"), nil)
      d = Events.append!(match_completed("r2"), nil)

      me = self()

      Events.replay_by_types(~w(match_created match_completed), fn event ->
        send(me, {:replayed, event.id})
      end)

      ids =
        Enum.map([a, b, c, d], fn _ ->
          assert_receive {:replayed, id}
          id
        end)

      assert ids == [a.id, b.id, c.id, d.id]
    end

    test "cursor option skips already-seen events" do
      a = Events.append!(match_created("c1"), nil)
      b = Events.append!(match_created("c2"), nil)

      me = self()

      Events.replay_by_types(~w(match_created), fn event -> send(me, {:replayed, event.id}) end,
        cursor: a.id
      )

      assert_receive {:replayed, id}
      assert id == b.id
      refute_receive {:replayed, _}
    end

    test "calls on_batch after each batch with last_id and processed count" do
      Enum.each(1..3, fn i -> Events.append!(match_created("b#{i}"), nil) end)

      me = self()

      Events.replay_by_types(
        ~w(match_created),
        fn _event -> :ok end,
        batch_size: 2,
        on_batch: fn last_id, processed -> send(me, {:batch, last_id, processed}) end
      )

      assert_receive {:batch, _last_id, 2}
      assert_receive {:batch, _last_id2, 3}
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

  describe "append!/2 — correlation columns" do
    test "populates match_id from domain event's mtga_match_id" do
      event = match_created("corr-match-1")
      record = Events.append!(event, nil)
      assert record.match_id == "corr-match-1"
      assert record.draft_id == nil
    end

    test "populates draft_id from domain event's mtga_draft_id" do
      event = %Events.Draft.DraftStarted{
        mtga_draft_id: "corr-draft-1",
        event_name: "PremierDraft",
        set_code: "FDN",
        occurred_at: ~U[2026-04-05 12:00:00Z]
      }

      record = Events.append!(event, nil)
      assert record.draft_id == "corr-draft-1"
      assert record.match_id == nil
    end

    test "populates session_id from opts" do
      event = match_created("corr-session-1")
      record = Events.append!(event, nil, session_id: "sess-abc-123")
      assert record.session_id == "sess-abc-123"
    end
  end

  describe "list_events/1" do
    test "returns all events with count when no filters" do
      Events.append!(match_created("list-1"), nil)
      Events.append!(match_created("list-2"), nil)
      Events.append!(match_completed("list-1"), nil)

      {events, count} = Events.list_events()
      assert count == 3
      assert length(events) == 3
    end

    test "filters by event_types" do
      Events.append!(match_created("type-1"), nil)
      Events.append!(match_completed("type-1"), nil)

      {events, count} = Events.list_events(event_types: ["match_created"])
      assert count == 1
      assert [%MatchCreated{}] = events
    end

    test "filters by match_id correlation" do
      Events.append!(match_created("filter-m-1"), nil)
      Events.append!(match_created("filter-m-2"), nil)
      Events.append!(match_completed("filter-m-1"), nil)

      {events, count} = Events.list_events(match_id: "filter-m-1")
      assert count == 2
      assert Enum.all?(events, fn e -> Map.get(e, :mtga_match_id) == "filter-m-1" end)
    end

    test "filters by session_id correlation" do
      Events.append!(match_created("sess-1"), nil, session_id: "session-aaa")
      Events.append!(match_created("sess-2"), nil, session_id: "session-bbb")

      {events, count} = Events.list_events(session_id: "session-aaa")
      assert count == 1
      assert [%MatchCreated{mtga_match_id: "sess-1"}] = events
    end

    test "filters by time range" do
      Events.append!(
        %MatchCreated{match_created("time-1") | occurred_at: ~U[2026-04-05 10:00:00Z]},
        nil
      )

      Events.append!(
        %MatchCreated{match_created("time-2") | occurred_at: ~U[2026-04-05 14:00:00Z]},
        nil
      )

      Events.append!(
        %MatchCreated{match_created("time-3") | occurred_at: ~U[2026-04-05 18:00:00Z]},
        nil
      )

      {events, count} =
        Events.list_events(
          since: ~U[2026-04-05 12:00:00Z],
          until: ~U[2026-04-05 16:00:00Z]
        )

      assert count == 1
      assert [%MatchCreated{mtga_match_id: "time-2"}] = events
    end

    test "paginates with limit and offset" do
      for i <- 1..5 do
        Events.append!(match_created("page-#{i}"), nil)
      end

      {page1, count} = Events.list_events(limit: 2, offset: 0)
      assert count == 5
      assert length(page1) == 2

      {page2, _} = Events.list_events(limit: 2, offset: 2)
      assert length(page2) == 2

      {page3, _} = Events.list_events(limit: 2, offset: 4)
      assert length(page3) == 1
    end

    test "text search on payload" do
      Events.append!(match_created("text-1"), nil)

      event_with_name = %MatchCreated{
        mtga_match_id: "text-2",
        event_name: "Traditional_Ladder",
        opponent_screen_name: "UniqueOpponent42",
        occurred_at: ~U[2026-04-05 12:00:00Z]
      }

      Events.append!(event_with_name, nil)

      {events, count} = Events.list_events(text_search: "UniqueOpponent42")
      assert count == 1
      assert [%MatchCreated{mtga_match_id: "text-2"}] = events
    end

    test "rehydrated events include player_id" do
      player = TestFactory.create_player()
      event = %MatchCreated{match_created("player-1") | player_id: player.id}
      Events.append!(event, nil)

      {[rehydrated], _} = Events.list_events(event_types: ["match_created"])
      assert rehydrated.player_id == player.id
    end

    test "returns events ordered by mtga_timestamp descending" do
      Events.append!(
        %MatchCreated{match_created("order-1") | occurred_at: ~U[2026-04-05 10:00:00Z]},
        nil
      )

      Events.append!(
        %MatchCreated{match_created("order-2") | occurred_at: ~U[2026-04-05 14:00:00Z]},
        nil
      )

      {events, _} = Events.list_events()
      ids = Enum.map(events, & &1.mtga_match_id)
      assert ids == ["order-2", "order-1"]
    end
  end

  describe "append_batch!/1" do
    test "inserts multiple domain events in one call" do
      source = TestFactory.create_event_record(%{event_type: "GreToClientEvent"})

      items = [
        {%Events.Gameplay.MulliganOffered{
           mtga_match_id: "batch-1",
           seat_id: 1,
           hand_size: 7,
           occurred_at: ~U[2026-04-05 12:00:00Z]
         }, source, [sequence: 0]},
        {%Events.Gameplay.MulliganOffered{
           mtga_match_id: "batch-1",
           seat_id: 2,
           hand_size: 7,
           occurred_at: ~U[2026-04-05 12:00:01Z]
         }, source, [sequence: 1]}
      ]

      :ok = Events.append_batch!(items)

      assert Events.count_by_type()["mulligan_offered"] == 2
    end

    test "duplicate items are silently skipped (idempotent)" do
      source = TestFactory.create_event_record(%{event_type: "GreToClientEvent"})

      item =
        {%Events.Gameplay.MulliganOffered{
           mtga_match_id: "idem-1",
           seat_id: 1,
           hand_size: 7,
           occurred_at: ~U[2026-04-05 12:00:00Z]
         }, source, [sequence: 0]}

      :ok = Events.append_batch!([item])
      :ok = Events.append_batch!([item])

      assert Events.count_by_type()["mulligan_offered"] == 1
    end

    test "empty list is a no-op" do
      :ok = Events.append_batch!([])
      assert Events.count_by_type() == %{}
    end
  end

  describe "projector suspension" do
    test "projector drops live events when suspended, processes them after resume" do
      alias Scry2.Matches.UpdateFromEvent

      proj_name = Module.concat(__MODULE__, :"SuspendTest#{System.unique_integer([:positive])}")
      start_supervised!({UpdateFromEvent, name: proj_name})

      UpdateFromEvent.suspend_live(proj_name)

      Events.append!(match_created("suspend-1"), nil)
      _ = :sys.get_state(proj_name)

      assert Scry2.Matches.count() == 0

      UpdateFromEvent.resume_live(proj_name)

      Events.append!(match_created("suspend-2"), nil)
      _ = :sys.get_state(proj_name)

      assert Scry2.Matches.count() == 1
    end
  end

  describe "replay_projections!/0" do
    test "rebuilds all projectors — data survives parallel execution" do
      import Scry2.ProjectorCase
      import Scry2.TestFactory

      player = create_player()
      scenario = match_scenario(player, games: [[won: true, on_play: true]], won: true)
      for event <- scenario.events, do: Events.append!(event, nil)

      Scry2.Repo.delete_all(Scry2.Matches.DeckSubmission)
      Scry2.Repo.delete_all(Scry2.Matches.Game)
      Scry2.Repo.delete_all(Scry2.Matches.Match)

      Events.replay_projections!()

      match = Scry2.Matches.get_by_mtga_id(scenario.match_id, player.id)
      assert match != nil
      assert match.won == true
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
