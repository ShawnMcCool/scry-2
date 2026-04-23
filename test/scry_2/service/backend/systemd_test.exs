defmodule Scry2.Service.Backend.SystemdTest do
  use ExUnit.Case, async: true

  alias Scry2.Service.Backend.Systemd

  defp fail_cmd, do: fn _binary, _args -> {"unit not found", 4} end

  defp cgroup_v2(unit) do
    fn -> {:ok, "0::/user.slice/user-1000.slice/user@1000.service/app.slice/#{unit}\n"} end
  end

  defp no_cgroup, do: fn -> {:error, :enoent} end

  describe "name/1" do
    test "uses detected unit from cgroup" do
      assert Systemd.name(cgroup_reader: cgroup_v2("scry-2-prod.service")) ==
               "systemd:scry-2-prod.service"
    end

    test "falls back to default unit when cgroup is unreadable" do
      assert Systemd.name(cgroup_reader: no_cgroup()) == "systemd:scry-2-dev.service"
    end
  end

  describe "capabilities/0" do
    test "supports restart, stop, and status" do
      assert Systemd.capabilities() == %{
               can_restart: true,
               can_stop: true,
               can_status: true
             }
    end
  end

  describe "state/1" do
    test "reports active+enabled+installed when systemctl agrees" do
      cmd_fn = fn
        "systemctl", ["--user", "list-unit-files", unit, "--no-pager"] ->
          {"#{unit} enabled", 0}

        _binary, _args ->
          {"", 0}
      end

      state = Systemd.state(cmd_fn: cmd_fn, cgroup_reader: cgroup_v2("scry-2-dev.service"))

      assert state.backend == :systemd
      assert state.unit == "scry-2-dev.service"
      assert state.systemd_available == true
      assert state.unit_installed == true
      assert state.active == true
      assert state.enabled == true
    end

    test "reports systemd_available=false when show-environment fails" do
      cmd_fn = fn
        "systemctl", ["--user", "show-environment"] -> {"", 1}
        _, _ -> {"", 0}
      end

      state = Systemd.state(cmd_fn: cmd_fn, cgroup_reader: cgroup_v2("scry-2-dev.service"))

      refute state.systemd_available
      refute state.active
      refute state.enabled
      refute state.unit_installed
    end

    test "reports active=false when is-active fails but systemctl is available" do
      cmd_fn = fn
        "systemctl", ["--user", "show-environment"] -> {"", 0}
        "systemctl", ["--user", "list-unit-files" | _] -> {"scry-2-dev.service enabled", 0}
        "systemctl", ["--user", "is-active", _] -> {"inactive", 3}
        "systemctl", ["--user", "is-enabled", _] -> {"enabled", 0}
        _, _ -> {"", 0}
      end

      state = Systemd.state(cmd_fn: cmd_fn, cgroup_reader: cgroup_v2("scry-2-dev.service"))

      assert state.systemd_available
      assert state.unit_installed
      refute state.active
      assert state.enabled
    end
  end

  describe "restart/1" do
    test "calls systemctl --user --no-block restart <unit>" do
      test_pid = self()

      cmd_fn = fn binary, args ->
        send(test_pid, {:cmd, binary, args})
        {"", 0}
      end

      assert :ok =
               Systemd.restart(cmd_fn: cmd_fn, cgroup_reader: cgroup_v2("scry-2-dev.service"))

      assert_receive {:cmd, "systemctl",
                      ["--user", "--no-block", "restart", "scry-2-dev.service"]}
    end

    test "returns {:error, ...} on non-zero exit" do
      assert {:error, {:systemctl_failed, 4, "unit not found"}} =
               Systemd.restart(cmd_fn: fail_cmd(), cgroup_reader: no_cgroup())
    end
  end

  describe "stop/1" do
    test "calls systemctl --user --no-block stop <unit>" do
      test_pid = self()

      cmd_fn = fn binary, args ->
        send(test_pid, {:cmd, binary, args})
        {"", 0}
      end

      assert :ok =
               Systemd.stop(cmd_fn: cmd_fn, cgroup_reader: cgroup_v2("scry-2-dev.service"))

      assert_receive {:cmd, "systemctl", ["--user", "--no-block", "stop", "scry-2-dev.service"]}
    end

    test "returns {:error, ...} on non-zero exit" do
      assert {:error, {:systemctl_failed, 4, "unit not found"}} =
               Systemd.stop(cmd_fn: fail_cmd(), cgroup_reader: no_cgroup())
    end
  end

  describe "cgroup parsing" do
    test "parses cgroup v2 single-line format" do
      reader = fn ->
        {:ok, "0::/user.slice/user-1000.slice/user@1000.service/app.slice/scry-2-dev.service\n"}
      end

      assert Systemd.name(cgroup_reader: reader) == "systemd:scry-2-dev.service"
    end

    test "parses cgroup v1 multi-line format and prefers the deepest .service" do
      # cgroup v1 has multiple controller:path lines.
      reader = fn ->
        {:ok,
         """
         12:cpu:/user.slice/user-1000.slice/user@1000.service/scry-2-dev.service
         11:memory:/user.slice/user-1000.slice/user@1000.service/scry-2-dev.service
         """}
      end

      assert Systemd.name(cgroup_reader: reader) == "systemd:scry-2-dev.service"
    end

    test "falls back when no .service segment present" do
      reader = fn -> {:ok, "0::/user.slice/some-other.scope\n"} end
      assert Systemd.name(cgroup_reader: reader) == "systemd:scry-2-dev.service"
    end
  end
end
