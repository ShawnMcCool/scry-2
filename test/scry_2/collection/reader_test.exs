defmodule Scry2.Collection.ReaderTest do
  use ExUnit.Case, async: true

  alias Scry2.Collection.Mem.TestBackend
  alias Scry2.Collection.Reader

  setup do
    TestBackend.clear_fixture()
    :ok
  end

  # Build a synthetic Dictionary<int,int> entries binary.
  defp entry(arena_id, count) do
    hash = Bitwise.band(arena_id, 0x7FFFFFFF)

    <<hash::little-signed-32, -1::little-signed-32, arena_id::little-signed-32,
      count::little-signed-32>>
  end

  defp cards_array(n, start_id) do
    Enum.map_join(0..(n - 1), "", fn offset ->
      entry(start_id + offset, rem(offset, 4) + 1)
    end)
  end

  test "reads the cards array end-to-end through TestBackend" do
    # Synthetic MTGA process layout:
    #   - heap region at 0x0800_0000 (rw-p anon), 16 KB span;
    #     cards dict sits at offset 0x1000 within it, 60 entries long.
    #   - MTGA.exe image base at 0x4000_0000 (r--p, MZ header).
    #   - mono + unity DLLs mapped, so discovery + self-check pass.
    heap_base = 0x0800_0000
    heap_size = 0x4000
    cards_offset = 0x1000
    cards_addr = heap_base + cards_offset
    cards = cards_array(60, 90_000)

    # Zero-fill the rest of the heap. Zero bytes fail both used_slot?
    # (key=0 is below 15_000) and empty_slot? (hash=0 != -1), so they
    # cleanly terminate the cards run.
    heap_bin =
      :binary.copy(<<0>>, cards_offset) <>
        cards <>
        :binary.copy(<<0>>, heap_size - cards_offset - byte_size(cards))

    mtga_exe_base = 0x4000_0000

    maps = [
      %{
        start: heap_base,
        end_addr: heap_base + heap_size,
        perms: "rw-p",
        path: nil
      },
      %{
        start: mtga_exe_base,
        end_addr: mtga_exe_base + 0x10_000,
        perms: "r--p",
        path: "C:/Wizards of the Coast/MTGA/MTGA.exe"
      },
      %{
        start: 0x5000_0000,
        end_addr: 0x5001_0000,
        perms: "r-xp",
        path: "/opt/mtga/MTGA_Data/Plugins/x86_64/mono-2.0-bdwgc.dll"
      },
      %{
        start: 0x6000_0000,
        end_addr: 0x6001_0000,
        perms: "r-xp",
        path: "/opt/mtga/MTGA_Data/Plugins/x86_64/UnityPlayer.dll"
      }
    ]

    TestBackend.set_fixture(
      processes: [%{pid: 4242, name: "MTGA.exe", cmdline: "C:/Wizards/MTGA/MTGA.exe"}],
      maps: maps,
      memory: [
        {heap_base, heap_bin},
        {mtga_exe_base, <<0x4D, 0x5A, 0x90, 0x00>>}
      ]
    )

    assert {:ok, result} =
             Reader.read(
               mem: TestBackend,
               scanner: [min_run: 50],
               chunk_size: heap_size,
               min_scan_entries: 50
             )

    assert result.card_count == 60
    assert result.total_copies == Enum.sum(for i <- 0..59, do: rem(i, 4) + 1)
    assert result.reader_confidence == "fallback_scan"
    assert result.entries_start == cards_addr
    assert result.region_start == heap_base
    assert {90_000, 1} in result.entries
  end

  test "returns :mtga_not_running when no MTGA process is visible" do
    TestBackend.set_fixture(processes: [])
    assert Reader.read(mem: TestBackend) == {:error, :mtga_not_running}
  end

  test "fails the discovery self-check when mono is not mapped" do
    TestBackend.set_fixture(
      processes: [%{pid: 1, name: "MTGA.exe", cmdline: ""}],
      maps: [
        %{start: 0x0, end_addr: 0x1, perms: "r--p", path: "MTGA.exe"},
        %{start: 0x2, end_addr: 0x3, perms: "r-xp", path: "UnityPlayer.dll"}
      ],
      memory: []
    )

    assert Reader.read(mem: TestBackend) ==
             {:error, {:check, :missing_mono_module}}
  end

  test "fails the scan self-check when no cards array is present" do
    heap_base = 0x1000_0000
    chunk = 0x1000
    # All-zero heap → scanner finds nothing.
    mtga_exe_base = 0x4000_0000

    TestBackend.set_fixture(
      processes: [%{pid: 1, name: "MTGA.exe", cmdline: ""}],
      maps: [
        %{start: heap_base, end_addr: heap_base + chunk, perms: "rw-p", path: nil},
        %{start: mtga_exe_base, end_addr: mtga_exe_base + 0x10, perms: "r--p", path: "MTGA.exe"},
        %{start: 0x0, end_addr: 0x1, perms: "r-xp", path: "mono-2.0-bdwgc.dll"},
        %{start: 0x2, end_addr: 0x3, perms: "r-xp", path: "UnityPlayer.dll"}
      ],
      memory: [
        {heap_base, :binary.copy(<<0>>, chunk)},
        {mtga_exe_base, <<0x4D, 0x5A>>}
      ]
    )

    assert Reader.read(mem: TestBackend, chunk_size: chunk, scanner: [min_run: 10]) ==
             {:error, :no_cards_array_found}
  end
end
