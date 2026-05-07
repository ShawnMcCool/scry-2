defmodule Scry2.Collection.ReaderTest do
  use ExUnit.Case, async: true

  alias Scry2.MtgaMemory.TestBackend
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

  describe "walker path" do
    defp walker_fixture(walker_snap) do
      %{
        processes: [%{pid: 1, name: "MTGA.exe", cmdline: ""}],
        maps: [
          %{start: 0x100, end_addr: 0x200, perms: "r-xp", path: "mono-2.0-bdwgc.dll"},
          %{start: 0x300, end_addr: 0x400, perms: "r-xp", path: "UnityPlayer.dll"}
        ],
        walker_snapshot: walker_snap
      }
    end

    defp valid_walker_snap do
      %{
        cards: [{70012, 1}, {82456, 4}, {91234, 2}, {44321, 1}],
        wildcards: %{common: 42, uncommon: 17, rare: 5, mythic: 2},
        gold: 12_345,
        gems: 3_000,
        vault_progress: 30.1,
        build_hint: "abc-123-guid",
        reader_version: "scry2-walker-0.1.0"
      }
    end

    test "walker success returns a walker-confidence result with flattened fields" do
      TestBackend.set_fixture(walker_fixture(valid_walker_snap()))

      assert {:ok, result} = Reader.read(mem: TestBackend, min_walker_cards: 1)

      assert result.reader_confidence == "walker"
      assert result.entries == [{70012, 1}, {82456, 4}, {91234, 2}, {44321, 1}]
      assert result.card_count == 4
      assert result.total_copies == 8
      assert result.wildcards_common == 42
      assert result.wildcards_uncommon == 17
      assert result.wildcards_rare == 5
      assert result.wildcards_mythic == 2
      assert result.gold == 12_345
      assert result.gems == 3_000
      assert result.vault_progress == 30.1
      assert result.mtga_build_hint == "abc-123-guid"
    end

    defp scanner_fallback_fixture(walker_snapshot_or_error) do
      heap_base = 0x0800_0000
      heap_size = 0x4000
      cards_offset = 0x1000
      cards = cards_array(60, 90_000)

      heap_bin =
        :binary.copy(<<0>>, cards_offset) <>
          cards <>
          :binary.copy(<<0>>, heap_size - cards_offset - byte_size(cards))

      mtga_exe_base = 0x4000_0000

      %{
        heap_base: heap_base,
        heap_size: heap_size,
        fixture: %{
          processes: [%{pid: 1, name: "MTGA.exe", cmdline: ""}],
          maps: [
            %{start: heap_base, end_addr: heap_base + heap_size, perms: "rw-p", path: nil},
            %{
              start: mtga_exe_base,
              end_addr: mtga_exe_base + 0x10,
              perms: "r--p",
              path: "C:/MTGA.exe"
            },
            %{start: 0x100, end_addr: 0x200, perms: "r-xp", path: "mono-2.0-bdwgc.dll"},
            %{start: 0x300, end_addr: 0x400, perms: "r-xp", path: "UnityPlayer.dll"}
          ],
          memory: [
            {heap_base, heap_bin},
            {mtga_exe_base, <<0x4D, 0x5A>>}
          ],
          walker_snapshot: walker_snapshot_or_error
        }
      }
    end

    test "walker error falls back to the scanner path" do
      # Walker errors → fall back. The fixture also carries a heap +
      # MTGA.exe stub so the scanner path can run.
      %{heap_size: heap_size, fixture: fixture} =
        scanner_fallback_fixture({:error, {:assembly_not_found, "Core"}})

      TestBackend.set_fixture(fixture)

      assert {:ok, result} =
               Reader.read(
                 mem: TestBackend,
                 scanner: [min_run: 50],
                 chunk_size: heap_size,
                 min_scan_entries: 50
               )

      assert result.reader_confidence == "fallback_scan"
      assert result.card_count == 60
      # mastery is always attempted after cards succeed, even on scanner path
      assert Map.has_key?(result, :mastery_tier)
      assert Map.has_key?(result, :mastery_season_name)
    end

    test "walker self-check failure also falls back to the scanner" do
      # Walker returns {:ok, snap} but the snap has 0 cards →
      # walker_result_ok?/2 fails → fall back to scanner.
      bad_snap = %{
        cards: [],
        wildcards: %{common: 0, uncommon: 0, rare: 0, mythic: 0},
        gold: 0,
        gems: 0,
        vault_progress: 0.0,
        build_hint: nil,
        reader_version: "scry2-walker-0.1.0"
      }

      %{heap_size: heap_size, fixture: fixture} = scanner_fallback_fixture(bad_snap)
      TestBackend.set_fixture(fixture)

      assert {:ok, result} =
               Reader.read(
                 mem: TestBackend,
                 scanner: [min_run: 50],
                 chunk_size: heap_size,
                 min_scan_entries: 50
               )

      assert result.reader_confidence == "fallback_scan"
      assert result.card_count == 60
      # mastery is always attempted after cards succeed, even on scanner path
      assert Map.has_key?(result, :mastery_tier)
      assert Map.has_key?(result, :mastery_season_name)
    end

    test "scanner-fallback path includes mastery when walk_mastery succeeds" do
      # walker self-check fails (0 cards) → scanner runs → mastery is still merged
      bad_snap = %{
        cards: [],
        wildcards: %{common: 0, uncommon: 0, rare: 0, mythic: 0},
        gold: 0,
        gems: 0,
        vault_progress: 0.0,
        build_hint: nil,
        reader_version: "scry2-walker-0.1.0"
      }

      mastery = %{
        tier: 5,
        xp_in_tier: 200,
        orbs: 3,
        season_name: "BattlePass_FDN",
        expiration_time_ticks: 639_178_128_000_000_000
      }

      %{heap_size: heap_size, fixture: base_fixture} = scanner_fallback_fixture(bad_snap)
      fixture = Map.put(base_fixture, :mastery_info, mastery)
      TestBackend.set_fixture(fixture)

      assert {:ok, result} =
               Reader.read(
                 mem: TestBackend,
                 scanner: [min_run: 50],
                 chunk_size: heap_size,
                 min_scan_entries: 50
               )

      assert result.reader_confidence == "fallback_scan"
      assert result.card_count == 60
      assert result.mastery_tier == 5
      assert result.mastery_xp_in_tier == 200
      assert result.mastery_orbs == 3
      assert result.mastery_season_name == "BattlePass_FDN"
      assert %DateTime{} = result.mastery_season_ends_at
    end

    test "walker success uses build_hint = nil cleanly" do
      snap = Map.put(valid_walker_snap(), :build_hint, nil)
      TestBackend.set_fixture(walker_fixture(snap))

      assert {:ok, result} = Reader.read(mem: TestBackend, min_walker_cards: 1)
      assert result.reader_confidence == "walker"
      assert result.mtga_build_hint == nil
    end

    test "walker success surfaces cards_version when present" do
      snap = Map.put(valid_walker_snap(), :cards_version, 4_217)
      TestBackend.set_fixture(walker_fixture(snap))

      assert {:ok, result} = Reader.read(mem: TestBackend, min_walker_cards: 1)
      assert result.mtga_player_cards_version == 4_217
    end

    test "walker success leaves cards_version nil when walker omits it" do
      # Older walker builds / unreachable chain → key absent.
      TestBackend.set_fixture(walker_fixture(valid_walker_snap()))

      assert {:ok, result} = Reader.read(mem: TestBackend, min_walker_cards: 1)
      assert result.mtga_player_cards_version == nil
    end
  end

  describe "walker mastery merge" do
    defp walker_fixture_with_mastery(walker_snap, mastery_info_or_unset) do
      base = %{
        processes: [%{pid: 1, name: "MTGA.exe", cmdline: ""}],
        maps: [
          %{start: 0x100, end_addr: 0x200, perms: "r-xp", path: "mono-2.0-bdwgc.dll"},
          %{start: 0x300, end_addr: 0x400, perms: "r-xp", path: "UnityPlayer.dll"}
        ],
        walker_snapshot: walker_snap
      }

      case mastery_info_or_unset do
        :unset -> base
        info -> Map.put(base, :mastery_info, info)
      end
    end

    defp valid_walker_snap_for_mastery do
      %{
        cards: [{70012, 1}, {82456, 4}, {91234, 2}, {44321, 1}],
        wildcards: %{common: 42, uncommon: 17, rare: 5, mythic: 2},
        gold: 12_345,
        gems: 3_000,
        vault_progress: 30.1,
        build_hint: "abc-123-guid",
        reader_version: "scry2-walker-0.1.0"
      }
    end

    test "merges mastery fields into params when walk_mastery returns a map" do
      mastery = %{
        tier: 17,
        xp_in_tier: 500,
        orbs: 0,
        season_name: "BattlePass_SOS",
        expiration_time_ticks: 639_178_128_000_000_000
      }

      TestBackend.set_fixture(
        walker_fixture_with_mastery(valid_walker_snap_for_mastery(), mastery)
      )

      assert {:ok, result} = Reader.read(mem: TestBackend, min_walker_cards: 1)

      assert result.reader_confidence == "walker"
      assert result.mastery_tier == 17
      assert result.mastery_xp_in_tier == 500
      assert result.mastery_orbs == 0
      assert result.mastery_season_name == "BattlePass_SOS"
      assert %DateTime{} = result.mastery_season_ends_at
    end

    test "leaves mastery columns nil when walk_mastery returns {:ok, nil}" do
      TestBackend.set_fixture(walker_fixture_with_mastery(valid_walker_snap_for_mastery(), nil))

      assert {:ok, result} = Reader.read(mem: TestBackend, min_walker_cards: 1)

      assert result.reader_confidence == "walker"
      assert result.mastery_tier == nil
      assert result.mastery_xp_in_tier == nil
      assert result.mastery_orbs == nil
      assert result.mastery_season_name == nil
      assert result.mastery_season_ends_at == nil
    end

    test "leaves mastery columns nil when walk_mastery returns {:error, _}" do
      # No :mastery_info key in the fixture → TestBackend returns
      # {:error, :no_mastery_info}.
      TestBackend.set_fixture(
        walker_fixture_with_mastery(valid_walker_snap_for_mastery(), :unset)
      )

      assert {:ok, result} = Reader.read(mem: TestBackend, min_walker_cards: 1)

      assert result.reader_confidence == "walker"
      assert result.mastery_tier == nil
      assert result.mastery_xp_in_tier == nil
      assert result.mastery_orbs == nil
      assert result.mastery_season_name == nil
      assert result.mastery_season_ends_at == nil
    end

    test "ticks → DateTime conversion is correct (.NET epoch offset)" do
      # 639_178_128_000_000_000 .NET ticks
      #   ÷ 10_000_000              → 63_917_812_800 seconds since 0001-01-01
      #   − 62_135_596_800          → 1_782_216_000 Unix seconds
      expected = DateTime.from_unix!(1_782_216_000)

      mastery = %{
        tier: 1,
        xp_in_tier: 0,
        orbs: 0,
        season_name: "Test",
        expiration_time_ticks: 639_178_128_000_000_000
      }

      TestBackend.set_fixture(
        walker_fixture_with_mastery(valid_walker_snap_for_mastery(), mastery)
      )

      assert {:ok, result} = Reader.read(mem: TestBackend, min_walker_cards: 1)
      assert result.mastery_season_ends_at == expected
    end

    test "zero or negative ticks → mastery_season_ends_at = nil" do
      mastery = %{
        tier: 1,
        xp_in_tier: 0,
        orbs: 0,
        season_name: "Sentinel",
        expiration_time_ticks: 0
      }

      TestBackend.set_fixture(
        walker_fixture_with_mastery(valid_walker_snap_for_mastery(), mastery)
      )

      assert {:ok, result} = Reader.read(mem: TestBackend, min_walker_cards: 1)
      assert result.mastery_season_name == "Sentinel"
      assert result.mastery_season_ends_at == nil
    end
  end
end
