defmodule Scry2.MtgaMemory.SelfTestTest do
  use ExUnit.Case, async: true

  alias Scry2.MtgaMemory.SelfTest
  alias Scry2.MtgaMemory.SelfTest.{Diagnosis, Report, WalkResult}
  alias Scry2.MtgaMemory.TestBackend

  setup do
    TestBackend.clear_fixture()
    :ok
  end

  defp wr(walk, outcome, reason \\ nil) do
    %WalkResult{
      walk: walk,
      outcome: outcome,
      reason: reason,
      reason_text: reason && Scry2.MtgaMemory.WalkError.translate(reason),
      elapsed_ms: 1
    }
  end

  @all_walks ~w(collection match_info match_board mastery events account cosmetics environment)a

  describe "diagnose/2" do
    test "no MTGA process → :mtga_not_running" do
      assert %Diagnosis{status: :mtga_not_running} = SelfTest.diagnose([], false)
    end

    test "all walks ok → :healthy" do
      results = Enum.map(@all_walks, &wr(&1, :ok))
      assert %Diagnosis{status: :healthy} = SelfTest.diagnose(results, true)
    end

    test "all walks empty → :healthy (empty is not broken)" do
      results = Enum.map(@all_walks, &wr(&1, :empty))
      diagnosis = SelfTest.diagnose(results, true)
      assert diagnosis.status == :healthy
    end

    test "mix of ok and empty → :healthy" do
      results = [
        wr(:collection, :ok),
        wr(:match_info, :empty),
        wr(:match_board, :empty),
        wr(:mastery, :empty),
        wr(:events, :empty),
        wr(:account, :ok),
        wr(:cosmetics, :ok),
        wr(:environment, :ok)
      ]

      assert %Diagnosis{status: :healthy} = SelfTest.diagnose(results, true)
    end

    test "all walks fail with :mono_dll_not_found → :runtime_not_ready" do
      results = Enum.map(@all_walks, &wr(&1, :error, :mono_dll_not_found))
      assert %Diagnosis{status: :runtime_not_ready} = SelfTest.diagnose(results, true)
    end

    test "all walks fail with :root_domain_not_found → :deep_break" do
      results = Enum.map(@all_walks, &wr(&1, :error, :root_domain_not_found))
      assert %Diagnosis{status: :deep_break} = SelfTest.diagnose(results, true)
    end

    test "some walks work, some broken → :partial with broken + working lists" do
      results = [
        wr(:collection, :error, {:class_not_found, "InventoryManager"}),
        wr(:match_info, :ok),
        wr(:match_board, :empty),
        wr(:mastery, :error, :chain_failed),
        wr(:events, :empty),
        wr(:account, :ok),
        wr(:cosmetics, :ok),
        wr(:environment, :ok)
      ]

      diagnosis = SelfTest.diagnose(results, true)
      assert diagnosis.status == :partial
      assert :collection in diagnosis.broken
      assert :mastery in diagnosis.broken
      refute :match_info in diagnosis.broken
      assert :match_info in diagnosis.working
      assert :match_board in diagnosis.working
    end

    test "diagnosis always carries a non-empty headline + detail" do
      for status_results <- [
            {false, []},
            {true, Enum.map(@all_walks, &wr(&1, :ok))},
            {true, Enum.map(@all_walks, &wr(&1, :error, :root_domain_not_found))}
          ] do
        {pid?, results} = status_results
        d = SelfTest.diagnose(results, pid?)
        assert is_binary(d.headline) and d.headline != ""
        assert is_binary(d.detail) and d.detail != ""
      end
    end
  end

  describe "to_text/1" do
    test "renders build hint, every walk row, and the diagnosis headline" do
      report = %Report{
        mtga_running: true,
        pid: 4242,
        build_hint: "BUILD-XYZ",
        reader_version: "scry2-walker-test",
        ran_at: ~U[2026-05-22 12:00:00Z],
        walks: [
          wr(:collection, :ok),
          wr(:mastery, :error, {:class_not_found, "AwsSetMasteryStrategy"})
        ],
        diagnosis: %Diagnosis{
          status: :partial,
          headline: "Some reads work, some are broken",
          detail: "broken: mastery",
          broken: [:mastery],
          working: [:collection]
        }
      }

      text = SelfTest.to_text(report)

      assert text =~ "BUILD-XYZ"
      assert text =~ "scry2-walker-test"
      assert text =~ "collection"
      assert text =~ "mastery"
      assert text =~ "AwsSetMasteryStrategy"
      assert text =~ "Some reads work, some are broken"
    end

    test "renders the mtga-not-running report without crashing" do
      report = %Report{
        mtga_running: false,
        pid: nil,
        build_hint: nil,
        reader_version: nil,
        ran_at: ~U[2026-05-22 12:00:00Z],
        walks: [],
        diagnosis: %Diagnosis{
          status: :mtga_not_running,
          headline: "MTGA isn't running",
          detail: "Start MTGA and try again.",
          broken: [],
          working: []
        }
      }

      text = SelfTest.to_text(report)
      assert text =~ "MTGA isn't running"
    end
  end

  describe "run/2" do
    test "no MTGA process → mtga_running: false, no walks attempted" do
      TestBackend.set_fixture(processes: [])

      report = SelfTest.run(TestBackend)

      assert report.mtga_running == false
      assert report.walks == []
      assert report.diagnosis.status == :mtga_not_running
    end

    test "classifies each walk: ok, empty, and error" do
      TestBackend.set_fixture(
        processes: [%{pid: 4242, name: "MTGA.exe", cmdline: "MTGA.exe"}],
        walker_snapshot: %{
          cards: [{1, 1}],
          wildcards: %{common: 0, uncommon: 0, rare: 0, mythic: 0},
          gold: 0,
          gems: 0,
          vault_progress: 0.0,
          build_hint: "BUILD-LIVE",
          reader_version: "scry2-walker-test",
          cards_version: 1
        },
        match_info: nil,
        board_snapshot: nil,
        mastery_info: {:error, {:class_not_found, "AwsSetMasteryStrategy"}},
        event_list: nil,
        account_identity: %{display_name: "Tester", external_id: "x"},
        cosmetics_summary: nil,
        environment_info: nil
      )

      report = SelfTest.run(TestBackend)

      assert report.mtga_running == true
      assert report.pid == 4242
      assert report.build_hint == "BUILD-LIVE"
      assert report.reader_version == "scry2-walker-test"

      by_walk = Map.new(report.walks, &{&1.walk, &1})

      assert by_walk[:collection].outcome == :ok
      assert by_walk[:match_info].outcome == :empty
      assert by_walk[:mastery].outcome == :error
      assert by_walk[:mastery].reason == {:class_not_found, "AwsSetMasteryStrategy"}
      assert by_walk[:account].outcome == :ok

      assert report.diagnosis.status == :partial
      assert :mastery in report.diagnosis.broken
    end

    test "all walks healthy → :healthy diagnosis" do
      ok_map = %{display_name: "x", external_id: "y"}

      TestBackend.set_fixture(
        processes: [%{pid: 7, name: "MTGA.exe", cmdline: "MTGA.exe"}],
        walker_snapshot: %{
          cards: [{1, 1}],
          wildcards: %{common: 0, uncommon: 0, rare: 0, mythic: 0},
          gold: 0,
          gems: 0,
          vault_progress: 0.0,
          build_hint: "BUILD-OK",
          reader_version: "v",
          cards_version: 1
        },
        match_info: nil,
        board_snapshot: nil,
        mastery_info: nil,
        event_list: nil,
        account_identity: ok_map,
        cosmetics_summary: nil,
        environment_info: nil
      )

      report = SelfTest.run(TestBackend)
      assert report.diagnosis.status == :healthy
    end
  end
end
