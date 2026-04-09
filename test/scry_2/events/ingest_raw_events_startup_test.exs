defmodule Scry2.Events.IngestRawEventsStartupTest do
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

  # Inserts a raw event record by parsing the fixture first.
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

  defp sync_pipeline(worker, projector) do
    _ = :sys.get_state(worker)
    _ = :sys.get_state(projector)
    :ok
  end

  # These tests each start their own IngestRawEvents worker and projector. They do NOT
  # use a shared module-level setup — having a pre-started competing worker would cause
  # a race where that worker (without the test's player context) wins the raw event
  # broadcast and writes a domain event with player_id: nil.

  describe "startup resume" do
    test "loads persisted state on init" do
      alias Scry2.Events.IngestionState
      alias Scry2.Events.IngestionState.Session

      player = Scry2.TestFactory.create_player(mtga_user_id: "known-user")

      IngestionState.persist!(%IngestionState{
        last_raw_event_id: 0,
        session: %Session{self_user_id: "known-user", player_id: player.id},
        match: %Scry2.Events.IngestionState.Match{}
      })

      worker_name = Module.concat(__MODULE__, :"Resume#{System.unique_integer([:positive])}")
      proj_name = Module.concat(__MODULE__, :"ResumeProj#{System.unique_integer([:positive])}")
      _proj = start_supervised!({UpdateFromEvent, name: proj_name}, id: proj_name)
      _pid = start_supervised!({IngestRawEvents, name: worker_name}, id: worker_name)

      _raw = insert_raw_from_fixture!("match_game_room_state_changed_playing.log")
      sync_pipeline(worker_name, proj_name)

      match = Matches.get_by_mtga_id("008b1926-09a8-40b4-872d-fa987588740c")
      assert match != nil
      assert match.player_id == player.id
    end

    test "catches up unprocessed events on init" do
      raw = insert_raw_from_fixture!("match_game_room_state_changed_playing.log")
      assert MtgaLogIngestion.get_event!(raw.id).processed == false

      catchup_name = Module.concat(__MODULE__, :"Catchup#{System.unique_integer([:positive])}")
      proj_name = Module.concat(__MODULE__, :"CatchupProj#{System.unique_integer([:positive])}")
      _proj = start_supervised!({UpdateFromEvent, name: proj_name}, id: proj_name)
      _worker = start_supervised!({IngestRawEvents, name: catchup_name}, id: catchup_name)

      # Give catch_up time to run (handle_continue is async)
      Process.sleep(100)

      assert MtgaLogIngestion.get_event!(raw.id).processed == true
      assert Events.count_by_type()["match_created"] == 1
    end
  end
end
