defmodule Scry2.MtgaLogs.PathResolverTest do
  use ExUnit.Case, async: true

  alias Scry2.MtgaLogs.PathResolver

  describe "resolve/1 with explicit candidate list" do
    test "returns the first existing file in the candidate list" do
      {tmp_a, tmp_b} = {tmp_file("a.log"), tmp_file("b.log")}
      File.write!(tmp_b, "real")

      assert {:ok, ^tmp_b} =
               PathResolver.resolve(candidates: [tmp_a, tmp_b])

      File.rm(tmp_b)
    end

    test "returns :not_found when no candidate exists" do
      assert {:error, :not_found} =
               PathResolver.resolve(
                 candidates: [tmp_file("missing-a.log"), tmp_file("missing-b.log")]
               )
    end

    test "override wins over candidate list" do
      tmp = tmp_file("override.log")
      File.write!(tmp, "contents")

      assert {:ok, ^tmp} =
               PathResolver.resolve(override: tmp, candidates: ["/does/not/exist.log"])

      File.rm(tmp)
    end

    test "override is rejected when the file doesn't exist" do
      fallback = tmp_file("fallback.log")
      File.write!(fallback, "fallback")

      # Even though we provide a valid candidate, the override is explicit —
      # if the user sets a path that doesn't exist we treat it as an error,
      # not a silent fall-through to defaults.
      assert {:error, :not_found} =
               PathResolver.resolve(override: "/nowhere/Player.log", candidates: [fallback])

      File.rm(fallback)
    end
  end

  describe "default_candidates/0" do
    test "contains the Steam Proton flatpak path first" do
      [first | _] = PathResolver.default_candidates()

      assert first =~ "com.valvesoftware.Steam"
      assert first =~ "compatdata/2141910"
      assert first =~ "Wizards Of The Coast/MTGA/Player.log"
    end

    test "includes macOS native path" do
      assert Enum.any?(
               PathResolver.default_candidates(),
               &String.contains?(&1, "Library/Logs/Wizards Of The Coast/MTGA/Player.log")
             )
    end
  end

  defp tmp_file(name) do
    Path.join(
      System.tmp_dir!(),
      "scry_2-pathresolver-#{System.unique_integer([:positive])}-#{name}"
    )
  end
end
