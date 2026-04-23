defmodule Scry2.Service.Backend.Tray do
  @moduledoc """
  Backend for prod installs supervised by the Go tray binary
  (`scry2-tray`) on Linux/macOS/Windows.

  ## Restart

  The tray watchdog polls `bin/scry_2 pid` every 10s; if the BEAM is
  not running it spawns a new one (after a 2s grace), unless the
  apply lock indicates an in-progress self-update. So `restart/1`
  here just calls `System.stop/1` — the tray's existing crash-recovery
  path takes over and respawns the BEAM.

  Total user-visible restart latency: roughly 12s (10s poll + 2s
  grace), plus normal BEAM boot.

  ## Stop is not supported

  Tray-managed "stop without restart" would require IPC the tray
  doesn't currently expose — the watchdog has no mechanism to be told
  "the user asked you to stop, don't relaunch." Adding that would
  mean either:

    * the tray exposing an HTTP/socket endpoint Elixir can call to
      flip a "user-requested-stop" flag, or
    * a sentinel file Elixir writes that the tray watchdog checks
      alongside the apply lock.

  Until that exists, `stop/1` returns `:not_supported` and the UI
  hides the Stop button.
  """

  @behaviour Scry2.Service.Backend

  require Scry2.Log, as: Log

  @impl true
  def name(_opts), do: "tray"

  @impl true
  def capabilities, do: %{can_restart: true, can_stop: false, can_status: true}

  @impl true
  def state(_opts) do
    # Under the tray, the BEAM is "active" by definition — this code is
    # running. The tray watchdog is responsible for keeping us up.
    %{backend: :tray, active: true}
  end

  @impl true
  def restart(opts) do
    system_stop_fn = Keyword.get(opts, :system_stop_fn, &System.stop/1)
    Log.info(:system, "tray-managed restart: System.stop(0) — watchdog will respawn")
    system_stop_fn.(0)
    :ok
  end

  @impl true
  def stop(_opts), do: :not_supported
end
