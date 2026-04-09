defmodule Scry2.Events.IngestRawEventsTest do
  use Scry2.DataCase

  alias Scry2.Events
  alias Scry2.Events.IngestRawEvents
  alias Scry2.Matches
  alias Scry2.Matches.UpdateFromEvent
  alias Scry2.MtgaLogIngestion

  # Reads a real fixture and returns its bytes.
  defp fixture(name) do
    File.read!(Path.join([__DIR__, "..", "..", "fixtures", "mtga_logs", name]))
  end

  # Inserts a raw event record by parsing the fixture first. Uses the
  # real ExtractEventsFromLog so the test exercises the whole translation path.
  defp insert_raw_from_fixture!(fixture_name) do
    chunk = fixture(fixture_name)
    base_offset = System.unique_integer([:positive]) * 100_000

    {[parsed], _warnings} =
      Scry2.MtgaLogIngestion.ExtractEventsFromLog.parse_chunk(chunk, "Player.log", base_offset)

    MtgaLogIngestion.insert_event!(%{
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

    _proj_pid = start_supervised!({UpdateFromEvent, name: proj_name})
    worker_pid = start_supervised!({IngestRawEvents, name: worker_name})

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
      reloaded = MtgaLogIngestion.get_event!(raw.id)
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
        MtgaLogIngestion.insert_event!(%{
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
      reloaded = MtgaLogIngestion.get_event!(raw.id)
      assert reloaded.processed == true
    end

    test "raw event types not handled by the translator are ignored silently",
         %{worker: worker, projector: projector, worker_pid: worker_pid} do
      raw =
        MtgaLogIngestion.insert_event!(%{
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
      reloaded = MtgaLogIngestion.get_event!(raw.id)
      assert reloaded.processed == true
    end
  end

  describe "checkpointing suspension" do
    test "suspend_checkpointing prevents IngestionState DB persistence during processing",
         %{worker: worker} do
      alias Scry2.Events.IngestionState

      IngestRawEvents.suspend_checkpointing(worker)

      raw = insert_raw_from_fixture!("match_game_room_state_changed_playing.log")
      _ = :sys.get_state(worker)

      loaded = IngestionState.load()
      assert loaded.last_raw_event_id < raw.id

      IngestRawEvents.resume_checkpointing(worker)
      raw2 = insert_raw_from_fixture!("match_game_room_state_changed_completed.log")
      _ = :sys.get_state(worker)

      loaded2 = IngestionState.load()
      assert loaded2.last_raw_event_id == raw2.id
    end
  end

  describe "retranslate_all!" do
    test "processes all events in id order and calls on_progress once per event",
         %{worker: worker, projector: projector} do
      raw1 = insert_raw_from_fixture!("match_game_room_state_changed_playing.log")
      raw2 = insert_raw_from_fixture!("match_game_room_state_changed_completed.log")
      sync_pipeline(worker, projector)

      # Simulate the reingest DB reset
      Scry2.Repo.delete_all(Scry2.Events.EventRecord)

      Scry2.MtgaLogIngestion.EventRecord
      |> Scry2.Repo.update_all(set: [processed: false, processed_at: nil, processing_error: nil])

      test_pid = self()

      IngestRawEvents.retranslate_all!(
        [on_progress: fn processed, total -> send(test_pid, {:progress, processed, total}) end],
        worker
      )

      # Domain events recreated from scratch
      counts = Events.count_by_type()
      assert counts["match_created"] == 1
      assert counts["match_completed"] == 1

      # All raw events marked processed
      assert MtgaLogIngestion.get_event!(raw1.id).processed == true
      assert MtgaLogIngestion.get_event!(raw2.id).processed == true

      # Progress callback called once per event with accurate counts
      assert_received {:progress, 1, 2}
      assert_received {:progress, 2, 2}
      refute_received {:progress, _, _}
    end

    test "works with no events", %{worker: worker} do
      IngestRawEvents.retranslate_all!([], worker)
      assert Events.count_by_type() == %{}
    end
  end
end
