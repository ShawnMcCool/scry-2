defmodule Scry2.MtgaLogIngestion.ReadNewBytesTest do
  use ExUnit.Case, async: true

  alias Scry2.MtgaLogIngestion.ReadNewBytes

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "scry_2-tailer-#{System.unique_integer([:positive])}.log"
      )

    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  test "read_since/2 returns empty bytes when offset equals file size", %{path: path} do
    File.write!(path, "hello world")

    assert {:ok, %{bytes: "", new_offset: 11, rotated?: false}} =
             ReadNewBytes.read_since(path, 11)
  end

  test "read_since/2 returns the full file when offset is 0", %{path: path} do
    File.write!(path, "hello world")

    assert {:ok, %{bytes: "hello world", new_offset: 11, rotated?: false}} =
             ReadNewBytes.read_since(path, 0)
  end

  test "read_since/2 returns only the new bytes after a partial read", %{path: path} do
    File.write!(path, "first chunk")
    {:ok, %{new_offset: offset}} = ReadNewBytes.read_since(path, 0)

    File.write!(path, "first chunksecond", [:write])
    # Reopen with append semantics to mimic log tailing.
    File.write!(path, "first chunksecond bytes")

    {:ok, result} = ReadNewBytes.read_since(path, offset)

    assert result.bytes == "second bytes"
    assert result.rotated? == false
    assert result.new_offset == byte_size("first chunksecond bytes")
  end

  test "read_since/2 flags rotation when file shrinks", %{path: path} do
    File.write!(path, "long original content")
    File.write!(path, "short")

    {:ok, result} = ReadNewBytes.read_since(path, 100)

    assert result.rotated? == true
    assert result.bytes == "short"
    assert result.new_offset == 5
  end

  test "read_since/2 reports error for missing file" do
    assert {:error, _} = ReadNewBytes.read_since("/does/not/exist/scry2-tailer.log", 0)
  end
end
