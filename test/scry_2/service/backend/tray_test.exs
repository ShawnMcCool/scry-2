defmodule Scry2.Service.Backend.TrayTest do
  use ExUnit.Case, async: true

  alias Scry2.Service.Backend.Tray

  describe "name/1" do
    test "returns 'tray'" do
      assert Tray.name([]) == "tray"
    end
  end

  describe "capabilities/0" do
    test "supports restart and status, but not stop" do
      assert Tray.capabilities() == %{
               can_restart: true,
               can_stop: false,
               can_status: true
             }
    end
  end

  describe "state/1" do
    test "always reports active=true (we're running by definition)" do
      assert %{backend: :tray, active: true} = Tray.state([])
    end
  end

  describe "restart/1" do
    test "calls system_stop_fn(0) — relies on tray watchdog to respawn" do
      test_pid = self()
      stop_fn = fn code -> send(test_pid, {:stopped, code}) end

      assert :ok = Tray.restart(system_stop_fn: stop_fn)
      assert_receive {:stopped, 0}
    end
  end

  describe "stop/1" do
    test "returns :not_supported (no IPC mechanism to tell tray 'don't relaunch')" do
      assert Tray.stop([]) == :not_supported
    end
  end
end
