defmodule Scry2.Collection.Mem.TestBackendTest do
  use ExUnit.Case, async: true

  alias Scry2.Collection.Mem.TestBackend

  setup do
    TestBackend.clear_fixture()
    :ok
  end

  describe "read_bytes/3" do
    test "returns bytes at the exact start of a stored region" do
      TestBackend.set_fixture(memory: [{0x1000, <<1, 2, 3, 4>>}])
      assert TestBackend.read_bytes(1, 0x1000, 4) == {:ok, <<1, 2, 3, 4>>}
    end

    test "returns a sub-slice when the read falls inside a region" do
      TestBackend.set_fixture(memory: [{0x1000, <<1, 2, 3, 4, 5, 6, 7, 8>>}])
      assert TestBackend.read_bytes(1, 0x1002, 4) == {:ok, <<3, 4, 5, 6>>}
    end

    test "returns :unmapped when the address is outside every region" do
      TestBackend.set_fixture(memory: [{0x1000, <<1, 2>>}])
      assert TestBackend.read_bytes(1, 0x9999, 4) == {:error, :unmapped}
    end

    test "returns :unmapped when the read spills past the region end" do
      TestBackend.set_fixture(memory: [{0x1000, <<1, 2, 3, 4>>}])
      assert TestBackend.read_bytes(1, 0x1002, 4) == {:error, :unmapped}
    end

    test "returns :no_fixture when no fixture has been set for the process" do
      assert TestBackend.read_bytes(1, 0x1000, 4) == {:error, :no_fixture}
    end
  end

  describe "list_maps/1" do
    test "returns the configured map entries verbatim" do
      maps = [
        %{start: 0x1000, end_addr: 0x2000, perms: "r-xp", path: "/proc/self/exe"},
        %{start: 0x3000, end_addr: 0x4000, perms: "rw-p", path: nil}
      ]

      TestBackend.set_fixture(maps: maps)
      assert TestBackend.list_maps(1) == {:ok, maps}
    end

    test "returns an empty list when the fixture omits :maps" do
      TestBackend.set_fixture(memory: [])
      assert TestBackend.list_maps(1) == {:ok, []}
    end

    test "returns :no_fixture when no fixture has been set" do
      assert TestBackend.list_maps(1) == {:error, :no_fixture}
    end
  end

  describe "find_process/1" do
    test "returns the pid of the first process that matches the predicate" do
      TestBackend.set_fixture(
        processes: [
          %{pid: 100, name: "bash", cmdline: "/bin/bash"},
          %{pid: 200, name: "MTGA", cmdline: "C:/MTGA/MTGA.exe"}
        ]
      )

      assert TestBackend.find_process(&(&1.name == "MTGA")) == {:ok, 200}
    end

    test "returns :not_found when no process matches" do
      TestBackend.set_fixture(processes: [%{pid: 100, name: "bash", cmdline: "/bin/bash"}])
      assert TestBackend.find_process(&(&1.name == "MTGA")) == {:error, :not_found}
    end

    test "returns :no_fixture when no fixture has been set" do
      assert TestBackend.find_process(fn _ -> true end) == {:error, :no_fixture}
    end
  end

  describe "walk_collection/1" do
    test "returns the configured :walker_snapshot fixture verbatim" do
      snap = %{
        cards: [{70012, 4}, {82456, 2}, {91234, 1}],
        wildcards: %{common: 42, uncommon: 17, rare: 5, mythic: 2},
        gold: 12_345,
        gems: 3_000,
        vault_progress: 250,
        build_hint: "abc-123-guid",
        reader_version: "scry2-walker-0.1.0"
      }

      TestBackend.set_fixture(walker_snapshot: snap)
      assert TestBackend.walk_collection(1) == {:ok, snap}
    end

    test "returns {:error, :no_walker_snapshot} when fixture is set but :walker_snapshot is omitted" do
      TestBackend.set_fixture(maps: [])
      assert TestBackend.walk_collection(1) == {:error, :no_walker_snapshot}
    end

    test "returns {:error, :no_fixture} when no fixture has been set" do
      assert TestBackend.walk_collection(1) == {:error, :no_fixture}
    end

    test "passes through any error tuple set in the fixture" do
      # Lets a test simulate the walker failing for a specific reason.
      TestBackend.set_fixture(walker_snapshot: {:error, {:assembly_not_found, "Core"}})
      assert TestBackend.walk_collection(1) == {:error, {:assembly_not_found, "Core"}}
    end
  end

  describe "dictionary<int,int> fixture exercises" do
    test "reads a synthetic Mono Dictionary<int,int> entries array field-by-field" do
      # A Mono-style Dictionary<int,int> entries array in .NET/Mono layout:
      # each entry is { int32 hash_code; int32 next; TKey key; TValue value }.
      # For <int,int> the entry size is 16 bytes. We lay out 3 entries.
      entries_base = 0x20_0000

      entry = fn hash, next, key, value ->
        <<hash::little-32, next::little-32, key::little-32, value::little-32>>
      end

      entries =
        IO.iodata_to_binary([
          entry.(0x1111_1111, -1, 70012, 4),
          entry.(0x2222_2222, -1, 82456, 2),
          entry.(0x3333_3333, -1, 91234, 1)
        ])

      TestBackend.set_fixture(memory: [{entries_base, entries}])

      assert {:ok, <<first_hash::little-32>>} = TestBackend.read_bytes(1, entries_base, 4)
      assert first_hash == 0x1111_1111

      # Second entry's key is at offset 16 + 8 = 24.
      assert {:ok, <<key2::little-32>>} = TestBackend.read_bytes(1, entries_base + 24, 4)
      assert key2 == 82456

      # Third entry's value is at offset 32 + 12 = 44.
      assert {:ok, <<value3::little-32>>} = TestBackend.read_bytes(1, entries_base + 44, 4)
      assert value3 == 1
    end
  end
end
