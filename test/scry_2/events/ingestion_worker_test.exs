defmodule Scry2.Events.IngestionWorkerTest do
  use Scry2.DataCase

  alias Scry2.Events
  alias Scry2.Events.IngestionWorker
  alias Scry2.Matches
  alias Scry2.Matches.Projector
  alias Scry2.MtgaLogs

  # Reads a real fixture and returns its bytes.
  defp fixture(name) do
    File.read!(Path.join([__DIR__, "..", "..", "fixtures", "mtga_logs", name]))
  end

  # Inserts a raw event record by parsing the fixture first. Uses the
  # real EventParser so the test exercises the whole translation path.
  defp insert_raw_from_fixture!(fixture_name) do
    chunk = fixture(fixture_name)
    [parsed] = Scry2.MtgaLogs.EventParser.parse_chunk(chunk, "Player.log", 0)

    MtgaLogs.insert_event!(%{
      event_type: parsed.type,
      mtga_timestamp: parsed.mtga_timestamp,
      file_offset: parsed.file_offset,
      source_file: "Player.log",
      raw_json: parsed.raw_json
    })
  end

  setup do
    # Start the full pipeline: ingestion worker (stage 08) + matches
    # projector (stage 09). Names are unique per test so the application
    # supervisor's instances (if any) don't collide.
    worker_name = Module.concat(__MODULE__, :"Worker#{System.unique_integer([:positive])}")
    proj_name = Module.concat(__MODULE__, :"Projector#{System.unique_integer([:positive])}")

    _proj_pid = start_supervised!({Projector, name: proj_name})
    worker_pid = start_supervised!({IngestionWorker, name: worker_name})

    %{worker: worker_name, worker_pid: worker_pid, projector: proj_name}
  end

  defp sync_pipeline(worker, projector) do
    _ = :sys.get_state(worker)
    _ = :sys.get_state(projector)
    :ok
  end

  describe "end-to-end: raw event → domain event → projection" do
    test "MatchGameRoomStateChangedEvent Playing becomes a match row",
         %{worker: worker, projector: projector} do
      raw = insert_raw_from_fixture!("match_game_room_state_changed_playing.log")
      sync_pipeline(worker, projector)

      # A domain event should have been appended.
      counts = Events.count_by_type()
      assert counts["match_created"] == 1

      # The projection should have the row.
      match = Matches.get_by_mtga_id("008b1926-09a8-40b4-872d-fa987588740c")
      assert match != nil
      assert match.event_name == "Traditional_Ladder"
      assert match.opponent_screen_name == "Opponent1"

      # The raw event should be marked processed.
      reloaded = MtgaLogs.get_event!(raw.id)
      assert reloaded.processed == true
    end

    test "MatchGameRoomStateChangedEvent MatchCompleted enriches the row",
         %{worker: worker, projector: projector} do
      _raw_playing = insert_raw_from_fixture!("match_game_room_state_changed_playing.log")
      _raw_completed = insert_raw_from_fixture!("match_game_room_state_changed_completed.log")
      sync_pipeline(worker, projector)

      # One domain event per raw event.
      counts = Events.count_by_type()
      assert counts["match_created"] == 1
      assert counts["match_completed"] == 1

      # One projected match row with both start and end data.
      assert Matches.count() == 1
      match = Matches.get_by_mtga_id("008b1926-09a8-40b4-872d-fa987588740c")
      assert match.started_at == ~U[2026-04-05 19:18:40Z]
      assert match.ended_at == ~U[2026-04-05 19:53:36Z]
      assert match.won == true
      assert match.num_games == 3
    end
  end

  describe "error handling" do
    test "malformed raw event is marked processed with no domain event created",
         %{worker: worker, projector: projector, worker_pid: worker_pid} do
      raw =
        MtgaLogs.insert_event!(%{
          event_type: "MatchGameRoomStateChangedEvent",
          file_offset: 0,
          source_file: "Player.log",
          raw_json: "{not valid json",
          processed: false
        })

      sync_pipeline(worker, projector)

      # Worker survives
      assert Process.alive?(worker_pid)

      # No domain events created (translator returned [])
      assert Events.count_by_type() == %{}

      # Raw event still marked processed — the "no domain events" path is
      # a normal outcome, not an error. Retranslation via
      # retranslate_from_raw!/0 would re-attempt if the translator changes.
      reloaded = MtgaLogs.get_event!(raw.id)
      assert reloaded.processed == true
    end

    test "raw event types not handled by the translator are ignored silently",
         %{worker: worker, projector: projector, worker_pid: worker_pid} do
      raw =
        MtgaLogs.insert_event!(%{
          event_type: "GraphGetGraphState",
          file_offset: 0,
          source_file: "Player.log",
          raw_json: ~s({"foo":"bar"}),
          processed: false
        })

      sync_pipeline(worker, projector)

      assert Process.alive?(worker_pid)
      assert Events.count_by_type() == %{}

      # Even unhandled types get marked processed so the worker doesn't
      # keep re-attempting them.
      reloaded = MtgaLogs.get_event!(raw.id)
      assert reloaded.processed == true
    end
  end
end
