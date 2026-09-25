defmodule Scry2.Cards.ImageCache.DiskUsageTest do
  use ExUnit.Case, async: true

  alias Scry2.Cards.ImageCache.DiskUsage

  @moduletag :tmp_dir

  describe "scan/1" do
    test "totals the cached images in the directory", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "91001.jpg"), "aaaa")
      File.write!(Path.join(tmp_dir, "91002-art.jpg"), "bbbbbb")

      usage = DiskUsage.scan(tmp_dir)

      assert usage.dir == tmp_dir
      assert usage.count == 2
      assert usage.bytes == 10
    end

    test "excludes the cache-version marker", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "cache-version"), "2")
      File.write!(Path.join(tmp_dir, "91001.jpg"), "aaaa")

      assert %DiskUsage{count: 1, bytes: 4} = DiskUsage.scan(tmp_dir)
    end

    test "excludes subdirectories", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "nested.jpg"))

      assert %DiskUsage{count: 0, bytes: 0} = DiskUsage.scan(tmp_dir)
    end

    test "reports nothing for a directory that does not exist", %{tmp_dir: tmp_dir} do
      missing = Path.join(tmp_dir, "never-created")

      assert %DiskUsage{dir: ^missing, count: 0, bytes: 0} = DiskUsage.scan(missing)
    end
  end

  describe "image_files/1" do
    test "lists the cached image paths and nothing else", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "cache-version"), "2")
      File.write!(Path.join(tmp_dir, "91001.jpg"), "art")

      assert DiskUsage.image_files(tmp_dir) == [Path.join(tmp_dir, "91001.jpg")]
    end

    test "returns nothing for a directory that does not exist", %{tmp_dir: tmp_dir} do
      assert DiskUsage.image_files(Path.join(tmp_dir, "never-created")) == []
    end
  end

  describe "add/4" do
    test "adds downloaded files to the running total", %{tmp_dir: tmp_dir} do
      usage = tmp_dir |> DiskUsage.scan() |> DiskUsage.add(tmp_dir, 2, 500)

      assert usage.count == 2
      assert usage.bytes == 500
    end

    test "ignores files written to a different directory", %{tmp_dir: tmp_dir} do
      usage = DiskUsage.scan(tmp_dir)

      assert DiskUsage.add(usage, Path.join(tmp_dir, "elsewhere"), 2, 500) == usage
    end
  end

  describe "reset/2" do
    test "zeroes the total when its own directory is cleared", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "91001.jpg"), "aaaa")

      usage = tmp_dir |> DiskUsage.scan() |> DiskUsage.reset(tmp_dir)

      assert usage.count == 0
      assert usage.bytes == 0
    end

    test "ignores a clear of a different directory", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "91001.jpg"), "aaaa")
      usage = DiskUsage.scan(tmp_dir)

      assert DiskUsage.reset(usage, Path.join(tmp_dir, "elsewhere")) == usage
    end
  end
end
