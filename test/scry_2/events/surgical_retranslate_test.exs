defmodule Scry2.Events.SurgicalRetranslateTest do
  @moduledoc """
  Stage 1b (ADR-042): the post-prune-safe retranslate.

  `Events.retranslate_from_raw!/0` refuses on any coverage gap and, when
  forced, deletes the ENTIRE domain log before rebuilding — so once a
  90-day prune has permanently orphaned old domain events, it can no longer
  regenerate the domain log after a translator change without losing that
  history.

  `Events.retranslate_covered!/1` is the surgical alternative: it deletes and
  rebuilds ONLY the domain events whose raw source still exists (the covered
  window), leaving orphaned (source-pruned) and synthetic (nil-source) domain
  events untouched. It seeds `self_user_id` from the persisted ingestion state
  so seat perspective survives a SessionStarted that fell out of the window.
  """
  use Scry2.DataCase

  alias Scry2.Events
  alias Scry2.Events.IngestionState
  alias Scry2.MtgaLogIngestion
  alias Scry2.TestFactory

  defp fixture(name) do
    File.read!(Path.join([__DIR__, "..", "..", "fixtures", "mtga_logs", name]))
  end

  # Inserts a raw event by parsing a real fixture through ExtractEventsFromLog,
  # exercising the real translation path on rebuild.
  defp insert_raw_from_fixture!(name) do
    chunk = fixture(name)
    base_offset = System.unique_integer([:positive]) * 100_000

    {[parsed], _warnings} =
      MtgaLogIngestion.ExtractEventsFromLog.parse_chunk(chunk, "Player.log", base_offset)

    MtgaLogIngestion.insert_event!(%{
      event_type: parsed.type,
      mtga_timestamp: parsed.mtga_timestamp,
      file_offset: parsed.file_offset,
      source_file: "Player.log",
      raw_json: parsed.raw_json
    })
  end

  describe "retranslate_covered!/1" do
    test "rebuilds domain events for surviving raw" do
      insert_raw_from_fixture!("authenticate_response.log")
      insert_raw_from_fixture!("match_game_room_state_changed_playing.log")

      assert :ok = Events.retranslate_covered!()
      assert Events.count_by_type()["match_created"] == 1
    end

    test "deletes stale domain events whose surviving raw no longer produces them" do
      # A raw row whose (factory) payload does not translate to a match, but
      # which carries a stale match_created domain event pointing at it.
      raw = TestFactory.create_event_record(%{event_type: "GreToClientEvent"})
      Events.append!(TestFactory.build_match_created(%{mtga_match_id: "stale"}), raw)

      assert :ok = Events.retranslate_covered!()

      # The stale event is deleted (covered window rebuilt); the raw produced nothing.
      refute Map.has_key?(Events.count_by_type(), "match_created")
    end

    test "keeps orphaned domain events whose raw source was pruned" do
      raw = TestFactory.create_event_record(%{event_type: "GreToClientEvent"})
      Events.append!(TestFactory.build_match_created(%{mtga_match_id: "orphan"}), raw)
      # Simulate the 90-day prune: raw gone, domain event orphaned.
      Repo.delete!(raw)

      assert :ok = Events.retranslate_covered!()

      # The orphaned event is preserved — it cannot be rebuilt, must not be lost.
      assert Events.count_by_type()["match_created"] == 1
    end

    test "keeps synthetic domain events with nil source" do
      Events.append!(TestFactory.build_match_created(%{mtga_match_id: "synthetic"}), nil)

      assert :ok = Events.retranslate_covered!()

      assert Events.count_by_type()["match_created"] == 1
    end

    test "does not refuse on a coverage gap (unlike retranslate_from_raw!)" do
      raw = TestFactory.create_event_record(%{event_type: "GreToClientEvent"})
      Events.append!(TestFactory.build_match_created(%{mtga_match_id: "gap"}), raw)
      Repo.delete!(raw)

      # retranslate_from_raw! would raise here; the surgical path must not.
      assert :ok = Events.retranslate_covered!()
      assert Events.count_by_type()["match_created"] == 1
    end

    test "seeds self_user_id from persisted state when its SessionStarted was pruned" do
      auth = insert_raw_from_fixture!("authenticate_response.log")

      assert :ok = Events.retranslate_covered!()
      seed = IngestionState.load().session.self_user_id
      assert is_binary(seed)

      # The SessionStarted's raw falls out of the retention window.
      Repo.delete!(auth)

      assert :ok = Events.retranslate_covered!()

      # Without seeding, rebuilding the now-empty window would reset this to nil.
      assert IngestionState.load().session.self_user_id == seed
    end
  end
end
