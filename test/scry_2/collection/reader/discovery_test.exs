defmodule Scry2.Collection.Reader.DiscoveryTest do
  use ExUnit.Case, async: true

  alias Scry2.Collection.Mem.TestBackend
  alias Scry2.Collection.Reader.Discovery

  setup do
    TestBackend.clear_fixture()
    :ok
  end

  test "returns MTGA's pid when the TestBackend exposes it" do
    TestBackend.set_fixture(
      processes: [
        %{pid: 100, name: "bash", cmdline: "/bin/bash"},
        %{pid: 9999, name: "MTGA.exe", cmdline: "C:/Wizards/MTGA/MTGA.exe"}
      ]
    )

    assert Discovery.find_mtga(TestBackend) == {:ok, 9999}
  end

  test "returns :mtga_not_running when no matching process is present" do
    TestBackend.set_fixture(processes: [%{pid: 100, name: "bash", cmdline: "/bin/bash"}])
    assert Discovery.find_mtga(TestBackend) == {:error, :mtga_not_running}
  end

  test "propagates backend errors verbatim" do
    # No fixture set → TestBackend returns {:error, :no_fixture}
    assert Discovery.find_mtga(TestBackend) == {:error, :no_fixture}
  end
end
