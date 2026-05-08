defmodule Scry2Web.NavUpdateScope do
  @moduledoc """
  LiveView `on_mount` hook that loads the self-update summary into socket
  assigns so the gear dropdown in the layout can show an "update
  available" badge from any page.

  Mirrors the `Scry2Web.PlayerScope` pattern: subscribes once per
  LiveView (only when `connected?(socket)` is true) and re-derives the
  summary from `Scry2.SelfUpdate` whenever a status broadcast lands. The
  attached `handle_info` hook always returns `{:cont, socket}` so host
  LiveViews (notably `Scry2Web.HealthLive`, which has its own richer
  apply-modal logic) keep receiving the same messages.

  ## Assigns set

    * `:nav_update` — `%{summary: UpdatesHelpers.summary()}` map. The
      gear dropdown reads `summary.status` and `summary.version` via
      `Scry2Web.NavHelpers.gear_indicator/1`.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  alias Scry2.SelfUpdate
  alias Scry2Web.SettingsLive.UpdatesHelpers

  def on_mount(:default, _params, _session, socket) do
    # Self-update is gated on Mix.env() == :prod at compile time. In dev
    # and test the subsystem is inert — there is no cron, no real check,
    # and no installer wired in. Show the gear without an "update
    # available" badge so dev sessions never invite an apply that would
    # do nothing useful (or worse, surface stale prod-cached data).
    if SelfUpdate.enabled?() do
      if connected?(socket), do: SelfUpdate.subscribe_status()

      socket =
        socket
        |> assign(:nav_update, build_nav_update())
        |> attach_hook(:nav_update_status, :handle_info, &handle_info/2)

      {:cont, socket}
    else
      {:cont, assign(socket, :nav_update, disabled_nav_update())}
    end
  end

  defp handle_info(:check_started, socket) do
    summary = Map.put(socket.assigns.nav_update.summary, :checking, true)
    {:cont, assign(socket, :nav_update, %{summary: summary})}
  end

  defp handle_info({:check_complete, _result}, socket) do
    {:cont, assign(socket, :nav_update, build_nav_update())}
  end

  defp handle_info(_other, socket), do: {:cont, socket}

  defp build_nav_update do
    %{
      summary:
        UpdatesHelpers.summarize(
          SelfUpdate.last_known_release(),
          SelfUpdate.current_version(),
          nil,
          nil,
          false
        )
    }
  end

  defp disabled_nav_update do
    %{summary: %{status: :no_data, checking: false}}
  end
end
