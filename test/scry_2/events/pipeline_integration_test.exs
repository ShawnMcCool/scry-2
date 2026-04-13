defmodule Scry2.Events.PipelineIntegrationTest do
  @moduledoc """
  Full pipeline integration tests exercising the chain:
  raw event → IngestRawEvents → domain event → projector GenServers → projection tables.

  Starts all pipeline components with unique names per test. Syncs via
  `:sys.get_state/1` to drain GenServer mailboxes before asserting.
  """
  use Scry2.DataCase

  alias Scry2.Events
  alias Scry2.Events.IngestRawEvents
  alias Scry2.Matches
  alias Scry2.MtgaLogIngestion

  defp fixture(name) do
    File.read!(Path.join([__DIR__, "..", "..", "fixtures", "mtga_logs", name]))
  end

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
    suffix = System.unique_integer([:positive])

    # Start all projectors first (subscribe before events arrive)
    _match_proj = start_supervised!({Scry2.Matches.MatchProjection, name: :"MatchProj#{suffix}"})

    _deck_proj = start_supervised!({Scry2.Decks.DeckProjection, name: :"DeckProj#{suffix}"})
    _draft_proj = start_supervised!({Scry2.Drafts.DraftProjection, name: :"DraftProj#{suffix}"})

    # Start the ingestion worker last (producer)
    worker_pid = start_supervised!({IngestRawEvents, name: :"Worker#{suffix}"})

    # Establish player context so all events are stamped with a player_id
    # and the "no player context" warning is never emitted during tests.
    insert_raw_from_fixture!("authenticate_response.log")
    _ = :sys.get_state(:"Worker#{suffix}")

    %{
      worker: :"Worker#{suffix}",
      worker_pid: worker_pid,
      projectors: %{
        matches: :"MatchProj#{suffix}",
        decks: :"DeckProj#{suffix}",
        drafts: :"DraftProj#{suffix}"
      }
    }
  end

  defp sync_pipeline(worker, projectors) do
    _ = :sys.get_state(worker)

    projectors
    |> Map.values()
    |> Enum.each(&:sys.get_state/1)

    :ok
  end

  describe "multi-projector pipeline" do
    test "match_created produces domain event and Matches projection",
         %{worker: worker, projectors: projectors} do
      _raw = insert_raw_from_fixture!("match_game_room_state_changed_playing.log")
      sync_pipeline(worker, projectors)

      assert Events.count_by_type()["match_created"] == 1

      match = Matches.get_by_mtga_id("008b1926-09a8-40b4-872d-fa987588740c")
      assert match != nil
      assert match.event_name == "Traditional_Ladder"
      assert match.opponent_screen_name == "Opponent1"
    end

    test "full match lifecycle populates match and game projections",
         %{worker: worker, projectors: projectors} do
      _raw_playing = insert_raw_from_fixture!("match_game_room_state_changed_playing.log")
      _raw_completed = insert_raw_from_fixture!("match_game_room_state_changed_completed.log")
      sync_pipeline(worker, projectors)

      counts = Events.count_by_type()
      assert counts["match_created"] == 1
      assert counts["match_completed"] == 1

      match = Matches.get_by_mtga_id("008b1926-09a8-40b4-872d-fa987588740c")
      assert match.won == true
      assert match.num_games == 3
      assert match.started_at != nil
      assert match.ended_at != nil
    end

    @tag capture_log: true
    test "error in raw event doesn't crash any process",
         %{worker: worker, worker_pid: worker_pid, projectors: projectors} do
      MtgaLogIngestion.insert_event!(%{
        event_type: "MatchGameRoomStateChangedEvent",
        file_offset: 0,
        source_file: "Player.log",
        raw_json: "{broken",
        processed: false
      })

      sync_pipeline(worker, projectors)

      assert Process.alive?(worker_pid)

      projectors
      |> Map.values()
      |> Enum.each(fn name ->
        assert Process.alive?(Process.whereis(name)),
               "projector #{name} should be alive"
      end)

      # Subsequent valid events still process
      _raw = insert_raw_from_fixture!("match_game_room_state_changed_playing.log")
      sync_pipeline(worker, projectors)

      assert Events.count_by_type()["match_created"] == 1
    end
  end

  describe "watermark advancement" do
    test "match-handling projectors advance watermarks after live events",
         %{worker: worker, projectors: projectors} do
      _raw = insert_raw_from_fixture!("match_game_room_state_changed_playing.log")
      sync_pipeline(worker, projectors)

      matches_watermark = Events.get_watermark("Matches.MatchProjection")
      assert matches_watermark > 0

      # Decks also claims match_created, so it advances too
      decks_watermark = Events.get_watermark("Decks.DeckProjection")
      assert decks_watermark > 0

      # Drafts doesn't handle match events — watermark stays at 0
      drafts_watermark = Events.get_watermark("Drafts.DraftProjection")
      assert drafts_watermark == 0
    end

    test "watermarks reach max event id after full lifecycle",
         %{worker: worker, projectors: projectors} do
      _raw_playing = insert_raw_from_fixture!("match_game_room_state_changed_playing.log")
      _raw_completed = insert_raw_from_fixture!("match_game_room_state_changed_completed.log")
      sync_pipeline(worker, projectors)

      max_id = Events.max_event_id()
      assert max_id > 0

      matches_watermark = Events.get_watermark("Matches.MatchProjection")
      assert matches_watermark == max_id
    end
  end
end
