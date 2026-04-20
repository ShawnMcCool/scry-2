defmodule Scry2.SelfUpdate.StagerTest do
  use ExUnit.Case, async: true
  alias Scry2.SelfUpdate.Stager

  @fixtures Path.expand("../../support/self_update_fixtures", __DIR__)

  setup do
    dir = System.tmp_dir!() |> Path.join("stager_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dest: dir}
  end

  describe "safe_entry?/1" do
    test "accepts normal paths" do
      assert Stager.safe_entry?("bin/scry_2") == true
      assert Stager.safe_entry?("share/systemd/scry_2.service") == true
      assert Stager.safe_entry?("lib/x/y.beam") == true
    end

    test "rejects absolute paths" do
      assert Stager.safe_entry?("/etc/passwd") == false
    end

    test "rejects parent-dir traversal anywhere in the path" do
      assert Stager.safe_entry?("../evil") == false
      assert Stager.safe_entry?("a/../b") == false
      assert Stager.safe_entry?("a/b/..") == false
    end

    test "rejects empty path" do
      assert Stager.safe_entry?("") == false
    end
  end

  describe "extract_tar/2" do
    test "extracts a valid tarball", %{dest: dest} do
      assert {:ok, root} =
               Stager.extract_tar(Path.join(@fixtures, "ok.tar.gz"), dest)

      assert File.exists?(Path.join(root, "bin/scry_2"))
    end

    test "rejects path traversal WITHOUT extracting anything", %{dest: dest} do
      assert {:error, :path_traversal} =
               Stager.extract_tar(Path.join(@fixtures, "traversal.tar.gz"), dest)

      # Security invariant: nothing should have been written outside dest.
      refute File.exists?(Path.join(Path.dirname(dest), "evil"))
    end
  end

  describe "extract_zip/2" do
    test "extracts a valid zip", %{dest: dest} do
      assert {:ok, root} =
               Stager.extract_zip(Path.join(@fixtures, "ok.zip"), dest)

      assert File.exists?(Path.join(root, "bin/scry_2.bat"))
    end
  end
end
