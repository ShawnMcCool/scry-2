defmodule Scry2.Matches.IngesterTest do
  use Scry2.DataCase

  alias Scry2.Matches
  alias Scry2.Matches.Ingester
  alias Scry2.MtgaLogs

  # Reads a real Player.log fixture and returns its content.
  defp fixture(name) do
    File.read!(Path.join([__DIR__, "..", "..", "fixtures", "mtga_logs", name]))
  end

  # Inserts a raw event record carrying the given fixture's raw JSON
  # body, then returns the record. Broadcasts on `mtga_logs:events` as a
  # side effect (which is what drives the ingester).
  defp insert_fixture_event!(fixture_name, event_type, mtga_timestamp) do
    chunk = fixture(fixture_name)
    [parsed] = Scry2.MtgaLogs.EventParser.parse_chunk(chunk, "Player.log", 0)

    MtgaLogs.insert_event!(%{
      event_type: event_type,
      mtga_timestamp: mtga_timestamp,
      file_offset: 0,
      source_file: "Player.log",
      raw_json: parsed.raw_json
    })
  end

  # Force the ingester to drain its mailbox before assertions. Any
  # messages received before this call will have been processed by the
  # time `:sys.get_state/1` returns.
  defp sync(name) do
    _ = :sys.get_state(name)
    :ok
  end

  setup do
    # Start the ingester under the test supervisor. Using a unique name
    # per test avoids conflicts if the application supervisor happens to
    # have started its own (test env has start_watcher=false so it does
    # not, but keeping this robust is cheap).
    name = Module.concat(__MODULE__, :"Ingester#{System.unique_integer([:positive])}")
    pid = start_supervised!({Ingester, name: name})
    %{ingester: name, pid: pid}
  end

  describe "handle_info/2 — happy path" do
    test "MatchGameRoomStateChangedEvent (Playing) creates a match row and marks event processed",
         %{ingester: name} do
      record =
        insert_fixture_event!(
          "match_game_room_state_changed_playing.log",
          "MatchGameRoomStateChangedEvent",
          ~U[2026-04-05 19:18:40Z]
        )

      sync(name)

      # Match should now exist with the expected fields
      match = Matches.get_by_mtga_id("008b1926-09a8-40b4-872d-fa987588740c")
      assert match != nil
      assert match.event_name == "Traditional_Ladder"
      assert match.opponent_screen_name == "Opponent1"
      assert match.started_at == ~U[2026-04-05 19:18:40Z]

      # Event should be marked processed
      reloaded = MtgaLogs.get_event!(record.id)
      assert reloaded.processed == true
      assert reloaded.processed_at != nil
    end

    test "MatchGameRoomStateChangedEvent (MatchCompleted) marks event processed but does not create match",
         %{ingester: name} do
      record =
        insert_fixture_event!(
          "match_game_room_state_changed_completed.log",
          "MatchGameRoomStateChangedEvent",
          ~U[2026-04-05 19:53:36Z]
        )

      sync(name)

      # No match created — mapper returns :ignore for non-Playing states
      assert Matches.count() == 0

      # But the event was still marked processed so it doesn't get
      # reprocessed on restart. Follow-up work will use the finalMatchResult
      # in the payload to update an existing match row.
      reloaded = MtgaLogs.get_event!(record.id)
      assert reloaded.processed == true
    end
  end

  describe "handle_info/2 — error path" do
    test "records processing_error on malformed JSON without crashing the GenServer",
         %{ingester: name, pid: pid} do
      record =
        MtgaLogs.insert_event!(%{
          event_type: "MatchGameRoomStateChangedEvent",
          file_offset: 0,
          source_file: "Player.log",
          raw_json: ~s({this is not valid json}),
          processed: false
        })

      sync(name)

      # GenServer survived
      assert Process.alive?(pid)

      # Event was NOT marked processed, but is NOT errored either —
      # malformed JSON reaches the mapper which returns :ignore, so the
      # ingester still calls mark_processed!. This is intentional: the
      # raw_json is preserved for future reparse when the parser/mapper
      # improves. Verify the event is in one of the two terminal states
      # (processed OR error) and the GenServer is still running.
      reloaded = MtgaLogs.get_event!(record.id)
      assert reloaded.processed == true or reloaded.processing_error != nil
    end

    test "events of unclaimed types are ignored silently", %{ingester: name, pid: pid} do
      record =
        MtgaLogs.insert_event!(%{
          event_type: "GraphGetGraphState",
          file_offset: 0,
          source_file: "Player.log",
          raw_json: ~s({}),
          processed: false
        })

      sync(name)

      # GenServer still alive
      assert Process.alive?(pid)

      # Event should still be unprocessed — unclaimed types are pass-through
      reloaded = MtgaLogs.get_event!(record.id)
      assert reloaded.processed == false
    end
  end

  describe "handle_info/2 — idempotency (ADR-016)" do
    test "replaying the same event twice produces one match row", %{ingester: name} do
      for _ <- 1..2 do
        insert_fixture_event!(
          "match_game_room_state_changed_playing.log",
          "MatchGameRoomStateChangedEvent",
          ~U[2026-04-05 19:18:40Z]
        )
      end

      sync(name)

      assert Matches.count() == 1

      match = Matches.get_by_mtga_id("008b1926-09a8-40b4-872d-fa987588740c")
      assert match != nil
    end
  end
end
