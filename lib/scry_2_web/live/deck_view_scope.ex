defmodule Scry2Web.DeckViewScope do
  @moduledoc """
  LiveView `on_mount` hook that wires the global deck composition
  preference — which sections render, which is on top, and how each
  section groups its cards.

  Sets:

    * `:deck_view_prefs` — a `CompositionPrefs` struct. Read once from
      `Settings.get/2` on mount; persisted on every change.
      `standard_composition/1` renders per these prefs.

  Attaches:

    * `handle_event("set_deck_view_pref", %{"field" => f, "to" => v},
      socket)` — whitelist-applies the field via `CompositionPrefs.put/3`,
      persists via `Settings.put!/2` when anything changed, re-assigns,
      and halts. The first write also removes the legacy
      `deck.display_mode` entry, which until then seeds `display_mode`
      for installs predating the prefs struct.

  Like `Scry2Web.SidebarScope`, this does not subscribe to
  `settings:updates`; cross-tab consistency on reload is acceptable for a
  chrome preference, and skipping the subscription keeps every page
  lighter. Within a page, the single assign drives every deck live.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  alias Scry2.Settings
  alias Scry2Web.DeckRendering.CompositionPrefs

  @setting_key "deck.view_prefs"
  @legacy_setting_key "deck.display_mode"

  def setting_key, do: @setting_key

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign(:deck_view_prefs, current_prefs())
      |> attach_hook(:deck_view_prefs, :handle_event, &handle_event/3)

    {:cont, socket}
  end

  # The new value travels as "to", not "value" — LiveView reserves the
  # "value" payload key for the clicked element's native value attribute,
  # which for a <button> is "" and would clobber a phx-value-value.
  defp handle_event("set_deck_view_pref", %{"field" => field, "to" => value}, socket) do
    prefs = socket.assigns.deck_view_prefs
    updated = CompositionPrefs.put(prefs, field, value)

    if updated != prefs do
      _ = Settings.put!(@setting_key, CompositionPrefs.to_stored(updated))
      :ok = Settings.delete(@legacy_setting_key)
    end

    {:halt, assign(socket, :deck_view_prefs, updated)}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp current_prefs do
    case Settings.get(@setting_key) do
      nil ->
        CompositionPrefs.put(
          %CompositionPrefs{},
          "display_mode",
          Settings.get(@legacy_setting_key)
        )

      stored ->
        CompositionPrefs.parse(stored)
    end
  end
end
