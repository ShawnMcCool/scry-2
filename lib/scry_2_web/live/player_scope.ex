defmodule Scry2Web.PlayerScope do
  @moduledoc """
  LiveView `on_mount` hook that loads the active player filter into
  socket assigns. Attach via `live_session` in the router.

  ## Assigns set

    * `:players` — list of all `%Player{}` records
    * `:active_player_id` — integer player id or nil (nil = all players)
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, push_patch: 2]

  alias Scry2.Players
  alias Scry2.Settings

  @settings_key "active_player_id"

  def on_mount(:default, _params, _session, socket) do
    players = Players.list_players()
    active_player_id = load_active_player_id(players)

    socket =
      socket
      |> assign(:players, players)
      |> assign(:active_player_id, active_player_id)
      |> assign(:player_scope_uri, "/")
      |> attach_hook(:player_scope_params, :handle_params, &handle_params/3)
      |> attach_hook(:player_scope_events, :handle_event, &handle_event/3)

    {:cont, socket}
  end

  defp handle_params(_params, uri, socket) do
    {:cont, assign(socket, :player_scope_uri, URI.parse(uri).path)}
  end

  defp handle_event("select_player", %{"player_id" => ""}, socket) do
    Settings.put!(@settings_key, nil)

    {:halt,
     socket
     |> assign(:active_player_id, nil)
     |> push_patch(to: socket.assigns.player_scope_uri)}
  end

  defp handle_event("select_player", %{"player_id" => player_id_str}, socket) do
    player_id = String.to_integer(player_id_str)
    Settings.put!(@settings_key, player_id)

    {:halt,
     socket
     |> assign(:active_player_id, player_id)
     |> push_patch(to: socket.assigns.player_scope_uri)}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp load_active_player_id(players) do
    case Settings.get(@settings_key) do
      nil ->
        nil

      id when is_integer(id) ->
        if Enum.any?(players, &(&1.id == id)), do: id

      _ ->
        nil
    end
  end
end
