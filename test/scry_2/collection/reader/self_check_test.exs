defmodule Scry2.Collection.Reader.SelfCheckTest do
  use ExUnit.Case, async: true

  alias Scry2.Collection.Mem.TestBackend
  alias Scry2.Collection.Reader.SelfCheck

  setup do
    TestBackend.clear_fixture()
    :ok
  end

  describe "discovery_ok?/1" do
    test "returns :ok when mono and UnityPlayer are both mapped" do
      maps = [
        %{
          start: 0x10_000,
          end_addr: 0x20_000,
          perms: "r-xp",
          path: "/opt/mtga/MTGA_Data/Plugins/x86_64/mono-2.0-bdwgc.dll"
        },
        %{
          start: 0x30_000,
          end_addr: 0x40_000,
          perms: "r-xp",
          path: "/opt/mtga/MTGA_Data/Plugins/x86_64/UnityPlayer.dll"
        }
      ]

      assert SelfCheck.discovery_ok?(maps) == :ok
    end

    test "flags missing mono runtime" do
      maps = [
        %{start: 0x0, end_addr: 0x1, perms: "r--p", path: "/opt/mtga/UnityPlayer.dll"}
      ]

      assert SelfCheck.discovery_ok?(maps) == {:error, {:check, :missing_mono_module}}
    end

    test "flags missing UnityPlayer" do
      maps = [
        %{start: 0x0, end_addr: 0x1, perms: "r--p", path: "/opt/mtga/mono-2.0-bdwgc.dll"}
      ]

      assert SelfCheck.discovery_ok?(maps) == {:error, {:check, :missing_unity_player}}
    end

    test "ignores mapping entries without a path" do
      maps = [
        %{start: 0x0, end_addr: 0x1, perms: "rw-p", path: nil},
        %{start: 0x2, end_addr: 0x3, perms: "r-xp", path: "/opt/mtga/mono-2.0-bdwgc.dll"},
        %{start: 0x4, end_addr: 0x5, perms: "r-xp", path: "/opt/mtga/UnityPlayer.dll"}
      ]

      assert SelfCheck.discovery_ok?(maps) == :ok
    end
  end

  describe "access_channel_ok?/3" do
    test "accepts a read that returns a PE MZ header" do
      mtga_exe_start = 0x4000_0000

      TestBackend.set_fixture(memory: [{mtga_exe_start, <<0x4D, 0x5A, 0x90, 0x00>>}])

      maps = [
        %{
          start: mtga_exe_start,
          end_addr: mtga_exe_start + 0x10_000,
          perms: "r--p",
          path: "C:/Wizards/MTGA/MTGA.exe"
        }
      ]

      assert SelfCheck.access_channel_ok?(TestBackend, 42, maps) == :ok
    end

    test "fails when MTGA.exe is not in the maps list" do
      maps = [%{start: 0x0, end_addr: 0x1, perms: "r--p", path: "/usr/lib/libc.so.6"}]
      TestBackend.set_fixture(memory: [])

      assert SelfCheck.access_channel_ok?(TestBackend, 42, maps) ==
               {:error, {:check, :mtga_exe_not_mapped}}
    end

    test "fails when the bytes at MTGA.exe's base are not MZ" do
      base = 0x5000_0000
      TestBackend.set_fixture(memory: [{base, <<0xFF, 0xFF>>}])

      maps = [%{start: base, end_addr: base + 0x10_000, perms: "r--p", path: "MTGA.exe"}]

      assert SelfCheck.access_channel_ok?(TestBackend, 42, maps) ==
               {:error, {:check, :not_pe_header}}
    end

    test "wraps backend read errors" do
      maps = [%{start: 0x1000, end_addr: 0x2000, perms: "r--p", path: "MTGA.exe"}]
      TestBackend.set_fixture(memory: [])

      assert {:error, {:check, {:read_failed, :unmapped}}} =
               SelfCheck.access_channel_ok?(TestBackend, 42, maps)
    end
  end

  describe "scan_result_ok?/1" do
    test "accepts a finding with a healthy distribution" do
      entries = for i <- 1..600, do: {30_000 + i, rem(i, 4) + 1}
      finding = %{entries: entries, entries_start: 0x1000, region_start: 0x0}

      assert SelfCheck.scan_result_ok?(finding) == :ok
    end

    test "flags a finding with too few entries" do
      entries = for i <- 1..100, do: {30_000 + i, 1}
      finding = %{entries: entries, entries_start: 0x1000, region_start: 0x0}

      assert {:error, {:check, {:scan_result_too_small, 100}}} =
               SelfCheck.scan_result_ok?(finding)
    end

    test "flags a finding where one count value dominates (uniform)" do
      entries = for i <- 1..1000, do: {30_000 + i, 1}
      finding = %{entries: entries, entries_start: 0x1000, region_start: 0x0}

      assert SelfCheck.scan_result_ok?(finding) ==
               {:error, {:check, :implausible_count_distribution}}
    end

    test "flags a finding with a non-positive arena_id" do
      entries = [{0, 1} | for(i <- 1..600, do: {30_000 + i, rem(i, 4) + 1})]
      finding = %{entries: entries, entries_start: 0x1000, region_start: 0x0}

      assert SelfCheck.scan_result_ok?(finding) ==
               {:error, {:check, :non_positive_arena_id}}
    end
  end

  describe "walker_result_ok?/2" do
    defp walker_snapshot(overrides \\ %{}) do
      Map.merge(
        %{
          cards: [{70012, 1}, {82456, 4}, {91234, 2}, {44321, 1}],
          wildcards: %{common: 42, uncommon: 17, rare: 5, mythic: 2},
          gold: 12_345,
          gems: 3_000,
          vault_progress: 250,
          build_hint: "abc-123-guid",
          reader_version: "scry2-walker-0.1.0"
        },
        overrides
      )
    end

    test "passes for a fully populated plausible snapshot" do
      assert SelfCheck.walker_result_ok?(walker_snapshot()) == :ok
    end

    test "passes when build_hint is nil (boot.config unreadable)" do
      assert SelfCheck.walker_result_ok?(walker_snapshot(%{build_hint: nil})) == :ok
    end

    test "flags an empty cards list" do
      assert SelfCheck.walker_result_ok?(walker_snapshot(%{cards: []})) ==
               {:error, {:check, :walker_no_cards}}
    end

    test "flags a non-positive arena_id" do
      cards = [{70012, 1}, {0, 4}]

      assert SelfCheck.walker_result_ok?(walker_snapshot(%{cards: cards})) ==
               {:error, {:check, :walker_non_positive_arena_id}}
    end

    test "flags a non-positive count" do
      cards = [{70012, 1}, {82456, 0}]

      assert SelfCheck.walker_result_ok?(walker_snapshot(%{cards: cards})) ==
               {:error, {:check, :walker_non_positive_count}}
    end

    test "flags a negative wildcard total" do
      wc = %{common: -1, uncommon: 17, rare: 5, mythic: 2}

      assert SelfCheck.walker_result_ok?(walker_snapshot(%{wildcards: wc})) ==
               {:error, {:check, :walker_negative_wildcards}}
    end

    test "flags negative gold" do
      assert SelfCheck.walker_result_ok?(walker_snapshot(%{gold: -1})) ==
               {:error, {:check, :walker_negative_gold}}
    end

    test "flags negative gems" do
      assert SelfCheck.walker_result_ok?(walker_snapshot(%{gems: -1})) ==
               {:error, {:check, :walker_negative_gems}}
    end

    test "flags negative vault_progress" do
      assert SelfCheck.walker_result_ok?(walker_snapshot(%{vault_progress: -1})) ==
               {:error, {:check, :walker_negative_vault_progress}}
    end

    test "flags an implausibly uniform count distribution" do
      # 100 cards all at count=1 — looks like a sentinel-fill, not a
      # real collection.
      cards = Enum.map(1..100, fn i -> {i, 1} end)

      assert SelfCheck.walker_result_ok?(walker_snapshot(%{cards: cards})) ==
               {:error, {:check, :walker_implausible_count_distribution}}
    end

    test "min_cards is configurable" do
      cards = [{70012, 1}, {82456, 4}]

      assert SelfCheck.walker_result_ok?(walker_snapshot(%{cards: cards}), min_cards: 5) ==
               {:error, {:check, {:walker_too_few_cards, 2}}}

      assert SelfCheck.walker_result_ok?(walker_snapshot(%{cards: cards}), min_cards: 1) == :ok
    end
  end
end
