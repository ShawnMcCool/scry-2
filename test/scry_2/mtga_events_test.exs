defmodule Scry2.MtgaEventsTest do
  use ExUnit.Case, async: true

  alias Scry2.MtgaEvents
  alias Scry2.MtgaMemory.TestBackend

  setup do
    TestBackend.clear_fixture()
    :ok
  end

  defp record(state, name \\ "Premier_Draft_DFT") do
    %{
      internal_event_name: name,
      current_event_state: state,
      current_module: 7,
      event_state: 0,
      format_type: 1,
      current_wins: 0,
      current_losses: 0,
      format_name: nil
    }
  end

  defp install_running_mtga(events) do
    TestBackend.set_fixture(
      processes: [%{pid: 1234, name: "MTGA.exe", cmdline: "MTGA.exe"}],
      event_list: %{records: events, reader_version: "test"}
    )
  end

  describe "read_active_events/1" do
    test "filters out available-but-untouched (state=0) entries" do
      install_running_mtga([
        record(0, "Some_Quick_Draft"),
        record(1, "Premier_Draft_SOS"),
        record(3, "Play"),
        record(0, "Constructed_Event_2026")
      ])

      assert {:ok, [r1, r2]} = MtgaEvents.read_active_events(mem: TestBackend)
      assert r1.internal_event_name == "Premier_Draft_SOS"
      assert r2.internal_event_name == "Play"
    end

    test "returns [] when EventManager anchor is null (pre-login)" do
      TestBackend.set_fixture(
        processes: [%{pid: 1234, name: "MTGA.exe", cmdline: "MTGA.exe"}],
        event_list: nil
      )

      assert {:ok, []} = MtgaEvents.read_active_events(mem: TestBackend)
    end

    test "returns [] when records list is empty" do
      install_running_mtga([])
      assert {:ok, []} = MtgaEvents.read_active_events(mem: TestBackend)
    end

    test "returns :mtga_not_running when no MTGA process is found" do
      TestBackend.set_fixture(processes: [])

      assert {:error, :mtga_not_running} =
               MtgaEvents.read_active_events(mem: TestBackend)
    end

    test "propagates walker errors" do
      TestBackend.set_fixture(
        processes: [%{pid: 1234, name: "MTGA.exe", cmdline: "MTGA.exe"}],
        event_list: {:error, :mono_dll_read_failed}
      )

      assert {:error, :mono_dll_read_failed} =
               MtgaEvents.read_active_events(mem: TestBackend)
    end

    test "returns all entries for a happy path with mixed states" do
      install_running_mtga([
        Map.merge(record(1), %{
          internal_event_name: "DualColorPrecons",
          current_wins: 22,
          current_losses: 17,
          format_name: "AllZeroes"
        }),
        record(3, "Play")
      ])

      assert {:ok, [precons, play]} = MtgaEvents.read_active_events(mem: TestBackend)
      assert precons.current_wins == 22
      assert precons.current_losses == 17
      assert play.internal_event_name == "Play"
    end
  end

  describe "actively_engaged?/1" do
    test "0 → not engaged" do
      refute MtgaEvents.actively_engaged?(record(0))
    end

    test "1 → engaged" do
      assert MtgaEvents.actively_engaged?(record(1))
    end

    test "3 → engaged" do
      assert MtgaEvents.actively_engaged?(record(3))
    end
  end
end
