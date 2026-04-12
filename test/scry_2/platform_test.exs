defmodule Scry2.PlatformTest do
  use ExUnit.Case, async: true

  alias Scry2.Platform

  describe "config_path/0" do
    test "returns a string ending in config.toml" do
      path = Platform.config_path()
      assert is_binary(path)
      assert String.ends_with?(path, "config.toml")
    end

    test "returns an absolute path" do
      path = Platform.config_path()
      assert absolute_path?(path)
    end

    test "includes scry_2 directory component" do
      assert Platform.config_path() =~ "scry_2"
    end
  end

  describe "data_dir/0" do
    test "returns a non-empty string" do
      dir = Platform.data_dir()
      assert is_binary(dir)
      assert String.length(dir) > 0
    end

    test "returns an absolute path" do
      assert absolute_path?(Platform.data_dir())
    end

    test "includes scry_2 directory component" do
      assert Platform.data_dir() =~ "scry_2"
    end
  end

  describe "mtga_log_candidates/0" do
    test "returns a non-empty list of strings" do
      candidates = Platform.mtga_log_candidates()
      assert is_list(candidates)
      assert length(candidates) > 0
      assert Enum.all?(candidates, &is_binary/1)
    end

    test "every candidate ends with Player.log" do
      for candidate <- Platform.mtga_log_candidates() do
        assert String.ends_with?(candidate, "Player.log"),
               "Expected #{candidate} to end with Player.log"
      end
    end

    test "every candidate is an absolute path" do
      for candidate <- Platform.mtga_log_candidates() do
        assert absolute_path?(candidate),
               "Expected #{candidate} to be an absolute path"
      end
    end
  end

  describe "mtga_raw_dir_candidates/0" do
    test "returns a non-empty list of strings" do
      candidates = Platform.mtga_raw_dir_candidates()
      assert is_list(candidates)
      assert length(candidates) > 0
      assert Enum.all?(candidates, &is_binary/1)
    end

    test "every candidate contains MTGA_Data" do
      for candidate <- Platform.mtga_raw_dir_candidates() do
        assert candidate =~ "MTGA_Data",
               "Expected #{candidate} to contain MTGA_Data"
      end
    end

    test "every candidate is an absolute path" do
      for candidate <- Platform.mtga_raw_dir_candidates() do
        assert absolute_path?(candidate),
               "Expected #{candidate} to be an absolute path"
      end
    end
  end

  describe "path construction" do
    test "no paths contain mixed separators (forward and back slashes)" do
      all_paths =
        [Platform.config_path(), Platform.data_dir()] ++
          Platform.mtga_log_candidates() ++
          Platform.mtga_raw_dir_candidates()

      for path <- all_paths do
        has_forward = String.contains?(path, "/")
        has_back = String.contains?(path, "\\")

        refute has_forward and has_back,
               "Path has mixed separators: #{path}"
      end
    end
  end

  # Absolute path detection that works cross-platform:
  # Unix: starts with /
  # Windows: starts with X:\ or X:/
  defp absolute_path?(path) do
    String.starts_with?(path, "/") or
      Regex.match?(~r/^[A-Za-z]:[\\\/]/, path)
  end
end
