defmodule Scry2.ConfigTestIsolationTest do
  @moduledoc """
  The test environment must not read or write the user's real data
  directory.

  `config/test.exs` already isolates the TOML lookup, the file log
  handler, console-setting persistence and the MTGA backend — but the
  config *defaults* were still derived from `Scry2.Platform.data_dir()`,
  so `cache_dir` and `image_cache_dir` pointed at the developer's live
  `~/.local/share/scry_2`.

  That made test timing depend on machine state: `Cards.data_source_stats/0`
  runs one `File.stat` per cached card image, so `/cards` mounted in 51ms
  on a machine with 3,826 cached images and would mount in milliseconds on
  a fresh clone. It flaked `PageSmokeTest` and failed a release.
  """
  use ExUnit.Case, async: true

  @real_data_dir Scry2.Platform.data_dir()

  describe "data directory isolation" do
    test "cache_dir is not the user's real data directory" do
      refute under?(Scry2.Config.get(:cache_dir), @real_data_dir),
             "test cache_dir leaks into the real data dir: #{Scry2.Config.get(:cache_dir)}"
    end

    test "image_cache_dir is not the user's real data directory" do
      dir = Scry2.Config.get(:image_cache_dir)

      refute under?(dir, @real_data_dir),
             "test image_cache_dir leaks into the real data dir: #{dir}"
    end

    test "the image cache the tests see is not the user's populated one" do
      # The specific failure mode: mount cost scaling with however many
      # card images the developer happens to have downloaded.
      dir = Scry2.Config.get(:image_cache_dir)

      count =
        case File.ls(dir) do
          {:ok, files} -> length(files)
          {:error, _} -> 0
        end

      assert count < 100,
             "tests are reading #{count} real cached images from #{dir}; " <>
               "page-mount timings will vary with developer machine state"
    end
  end

  defp under?(nil, _root), do: false

  defp under?(path, root) do
    String.starts_with?(Path.expand(path), Path.expand(root))
  end
end
