defmodule Scry2.Service.Backend.Systemd do
  @moduledoc """
  Systemd `--user` unit backend (Linux dev).

  Detection signal is `INVOCATION_ID` in the environment — systemd sets
  this for every unit execution. The unit name is parsed from
  `/proc/self/cgroup`; `*.service` is the last path segment under both
  cgroup v1 and v2.

  ## Process model

  Restart and stop use `systemctl --user --no-block …`. `--no-block`
  queues the job and returns immediately. That matters for restart:
  without it, systemctl would wait for `ExecStop` to finish, but
  `ExecStop` kills the very BEAM that spawned it — so the caller would
  deadlock. With `--no-block` the call returns, systemd kills the BEAM
  asynchronously, and LiveView reconnects to the new BEAM.
  """

  @behaviour Scry2.Service.Backend

  require Scry2.Log, as: Log

  @default_unit "scry-2-dev.service"

  @impl true
  def name(opts), do: "systemd:" <> resolve_unit(opts)

  @impl true
  def capabilities, do: %{can_restart: true, can_stop: true, can_status: true}

  @impl true
  def state(opts) do
    cmd_fn = Keyword.get(opts, :cmd_fn, &default_cmd/2)
    unit = resolve_unit(opts)
    available = systemd_available?(cmd_fn)

    %{
      backend: :systemd,
      unit: unit,
      systemd_available: available,
      unit_installed: available and unit_installed?(cmd_fn, unit),
      active: available and active?(cmd_fn, unit),
      enabled: available and enabled?(cmd_fn, unit)
    }
  end

  @impl true
  def restart(opts) do
    cmd_fn = Keyword.get(opts, :cmd_fn, &default_cmd/2)
    unit = resolve_unit(opts)
    Log.info(:system, "restarting #{unit} via systemctl --user")
    systemctl(cmd_fn, ["--user", "--no-block", "restart", unit])
  end

  @impl true
  def stop(opts) do
    cmd_fn = Keyword.get(opts, :cmd_fn, &default_cmd/2)
    unit = resolve_unit(opts)
    Log.info(:system, "stopping #{unit} via systemctl --user")
    systemctl(cmd_fn, ["--user", "--no-block", "stop", unit])
  end

  defp systemctl(cmd_fn, args) do
    case cmd_fn.("systemctl", args) do
      {_output, 0} -> :ok
      {output, code} -> {:error, {:systemctl_failed, code, String.trim(output)}}
    end
  end

  defp resolve_unit(opts) do
    cgroup_reader = Keyword.get(opts, :cgroup_reader, &default_cgroup_reader/0)

    case detect_unit(cgroup_reader) do
      nil -> @default_unit
      unit -> unit
    end
  end

  defp detect_unit(cgroup_reader) do
    case cgroup_reader.() do
      {:ok, contents} -> parse_cgroup_unit(contents)
      _ -> nil
    end
  end

  # Scans each line for a `*.service` segment and returns the deepest
  # one. cgroup v2 has a single line like
  # `0::/user.slice/.../scry-2-dev.service`; v1 has multiple
  # `controller:path` lines.
  defp parse_cgroup_unit(contents) when is_binary(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.map(&extract_service_from_line/1)
    |> Enum.reject(&is_nil/1)
    |> List.last()
  end

  defp parse_cgroup_unit(_), do: nil

  defp extract_service_from_line(line) do
    line
    |> String.split("/")
    |> Enum.reverse()
    |> Enum.find(&String.ends_with?(&1, ".service"))
  end

  defp default_cgroup_reader, do: File.read("/proc/self/cgroup")

  defp systemd_available?(cmd_fn) do
    case cmd_fn.("systemctl", ["--user", "show-environment"]) do
      {_output, 0} -> true
      _ -> false
    end
  catch
    _, _ -> false
  end

  defp unit_installed?(cmd_fn, unit) do
    case cmd_fn.("systemctl", ["--user", "list-unit-files", unit, "--no-pager"]) do
      {output, 0} -> String.contains?(output, unit)
      _ -> false
    end
  end

  defp active?(cmd_fn, unit) do
    case cmd_fn.("systemctl", ["--user", "is-active", unit]) do
      {_output, 0} -> true
      _ -> false
    end
  end

  defp enabled?(cmd_fn, unit) do
    case cmd_fn.("systemctl", ["--user", "is-enabled", unit]) do
      {_output, 0} -> true
      _ -> false
    end
  end

  # Forward the env vars `systemctl --user` needs (XDG_RUNTIME_DIR,
  # DBUS_SESSION_BUS_ADDRESS) without re-widening the attack surface
  # to the whole inherited env.
  defp default_cmd(binary, args) do
    resolved = System.find_executable(binary) || binary

    keep =
      Enum.flat_map(["XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"], fn name ->
        case System.get_env(name) do
          nil -> []
          "" -> []
          value -> [{name, value}]
        end
      end)

    System.cmd(resolved, args, stderr_to_stdout: true, env: keep)
  rescue
    ErlangError -> {"", 127}
  end
end
