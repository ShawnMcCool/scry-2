defmodule Scry2.Service do
  @moduledoc """
  Cross-platform abstraction for whoever is supervising this BEAM.

  Three backends, picked by `detect/0`:

  | Backend     | Detection                                         | Capabilities                       |
  |-------------|---------------------------------------------------|------------------------------------|
  | `Systemd`   | `INVOCATION_ID` env var present                   | restart, stop, status, logs        |
  | `Tray`      | `SCRY2_SUPERVISOR=tray` env, or `:prod` Mix env   | restart (via `System.stop/1`)      |
  | `Unmanaged` | dev `mix phx.server`, IEx, tests                  | status only                        |

  ## Why three backends

  Linux dev runs under a systemd `--user` unit (`scry-2-dev`), which can
  cleanly restart/stop the BEAM via `systemctl`. The prod install path on
  every OS (Linux/macOS/Windows) uses the Go tray binary as the
  supervisor — the cleanest "restart" there is to call `System.stop/1`
  and rely on the tray watchdog (10s poll + 2s grace) to respawn.

  The abstraction lets the LiveView render a uniform "Service" card
  with the correct buttons enabled per backend, without any
  `case Platform.os()` branching at the call site.

  ## Capabilities

  Every backend implements `capabilities/0`. The UI gates buttons on
  these flags rather than on the backend module name — that keeps the
  rendering logic stable as new backends (e.g. macOS LaunchAgent,
  Windows service) are added.

  ## Test injection

  All operations are wrapped in functions accepting `:cmd_fn` /
  `:env_fn` opts so tests can assert behaviour without ever shelling
  out or stopping the real BEAM.
  """

  alias Scry2.Service.Backend

  @type backend :: module()

  # Capture mix env at compile time. `Mix` is not loaded in prod releases —
  # calling `Mix.env()` at runtime crashes the LiveView that calls into here.
  @compile_mix_env Mix.env()

  @spec detect(keyword()) :: backend()
  def detect(opts \\ []) do
    env_fn = Keyword.get(opts, :env_fn, &System.get_env/1)
    mix_env = Keyword.get(opts, :mix_env, @compile_mix_env)

    cond do
      under_systemd?(env_fn) -> Backend.Systemd
      tray_supervisor?(env_fn, mix_env) -> Backend.Tray
      true -> Backend.Unmanaged
    end
  end

  @spec name(keyword()) :: String.t()
  def name(opts \\ []), do: backend(opts).name(opts)

  @spec state(keyword()) :: map()
  def state(opts \\ []), do: backend(opts).state(opts)

  @spec capabilities(keyword()) :: %{
          can_restart: boolean(),
          can_stop: boolean(),
          can_status: boolean()
        }
  def capabilities(opts \\ []), do: backend(opts).capabilities()

  @spec restart(keyword()) :: :ok | {:error, term()} | :not_supported
  def restart(opts \\ []), do: backend(opts).restart(opts)

  @spec stop(keyword()) :: :ok | {:error, term()} | :not_supported
  def stop(opts \\ []), do: backend(opts).stop(opts)

  defp backend(opts), do: Keyword.get(opts, :backend) || detect(opts)

  defp under_systemd?(env_fn) do
    case env_fn.("INVOCATION_ID") do
      nil -> false
      "" -> false
      _ -> true
    end
  end

  defp tray_supervisor?(env_fn, mix_env) do
    case env_fn.("SCRY2_SUPERVISOR") do
      "tray" -> true
      _ -> mix_env == :prod
    end
  end
end
