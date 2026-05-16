defmodule Scry2Web.SidebarScope do
  @moduledoc """
  LiveView `on_mount` hook that wires the collapsible left-rail sidebar.

  Sets:

    * `:sidebar_collapsed` — boolean. `false` (expanded) by default. Read
      once from `Settings.get/2` on mount; persisted on every toggle.

  Attaches:

    * `handle_event("toggle_sidebar", _, socket)` — flips
      `:sidebar_collapsed`, persists the new value via `Settings.put!/2`,
      and continues.

  The toggle does not subscribe to `settings:updates`; cross-tab
  consistency on reload is acceptable for a chrome preference, and
  skipping the subscription keeps every page lighter.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  alias Scry2.Settings

  @setting_key "nav.sidebar_collapsed"

  def setting_key, do: @setting_key

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign(:sidebar_collapsed, current_collapsed())
      |> attach_hook(:sidebar_toggle, :handle_event, &handle_event/3)

    {:cont, socket}
  end

  defp handle_event("toggle_sidebar", _params, socket) do
    new_value = not socket.assigns.sidebar_collapsed
    _ = Settings.put!(@setting_key, new_value)
    {:halt, assign(socket, :sidebar_collapsed, new_value)}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp current_collapsed do
    case Settings.get(@setting_key, false) do
      true -> true
      _ -> false
    end
  end
end
