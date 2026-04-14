defmodule Scry2.Events.PipelineHashTest do
  use ExUnit.Case, async: true

  alias Scry2.Events.PipelineHash

  describe "translator_hash/0" do
    test "returns a string" do
      assert is_binary(PipelineHash.translator_hash())
    end

    test "returns a stable value across calls" do
      assert PipelineHash.translator_hash() == PipelineHash.translator_hash()
    end

    test "returns a non-empty numeric string" do
      hash = PipelineHash.translator_hash()
      assert String.length(hash) > 0
      assert {_integer, ""} = Integer.parse(hash)
    end
  end

  describe "hashed_files/0" do
    test "includes translator-layer files" do
      files = PipelineHash.hashed_files()
      assert "lib/scry_2/events/identify_domain_events.ex" in files
      assert "lib/scry_2/events/enrich_events.ex" in files
      assert "lib/scry_2/events/snapshot_diff.ex" in files
      assert "lib/scry_2/events/snapshot_convert.ex" in files
      assert "lib/scry_2/events/ingestion_state.ex" in files
    end

    test "includes domain event struct files" do
      files = PipelineHash.hashed_files()
      assert Enum.any?(files, &String.contains?(&1, "match/match_created.ex"))
      assert Enum.any?(files, &String.contains?(&1, "draft/draft_started.ex"))
      assert Enum.any?(files, &String.contains?(&1, "gameplay/card_drawn.ex"))
      assert Enum.any?(files, &String.contains?(&1, "economy/inventory_snapshot.ex"))
      assert Enum.any?(files, &String.contains?(&1, "progression/rank_snapshot.ex"))
      assert Enum.any?(files, &String.contains?(&1, "session/session_started.ex"))
    end

    test "excludes infrastructure files" do
      files = PipelineHash.hashed_files()
      refute Enum.any?(files, &String.contains?(&1, "projector.ex"))
      refute Enum.any?(files, &String.contains?(&1, "projector_registry.ex"))
      refute Enum.any?(files, &String.contains?(&1, "projector_watermark.ex"))
      refute Enum.any?(files, &String.contains?(&1, "version_check.ex"))
      refute Enum.any?(files, &String.contains?(&1, "pipeline_hash.ex"))
    end

    test "all listed files exist on disk" do
      for file <- PipelineHash.hashed_files() do
        assert File.exists?(file), "expected #{file} to exist"
      end
    end
  end
end
