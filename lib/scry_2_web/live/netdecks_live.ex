defmodule Scry2Web.NetdecksLive do
  @moduledoc """
  LiveView for the NetDecking corpus catalog.

  Groups all reference decks by buildability status — Buildable now / Craftable now /
  Within reach — so the player immediately sees what they can take to a match.

  Mount loads `Scry2.NetDecking.catalog/0` and re-scores live whenever a new
  collection snapshot arrives. A paste-import box lets the player add decks
  from an MTGA clipboard decklist. Detail view (`/netdecks/:id`) shows an
  MTGA-ready import string for the selected deck.

  All non-trivial logic lives in `Scry2Web.NetdecksHelpers` (ADR-013). This
  module is thin wiring: mount, event dispatch, and template rendering only.
  """
  use Scry2Web, :live_view

  alias Scry2.Cards
  alias Scry2.Decks.Deck
  alias Scry2.Decks.MtgaClipboardFormat
  alias Scry2.NetDecking
  alias Scry2.Topics
  alias Scry2Web.NetdecksHelpers

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Topics.subscribe(Topics.collection_snapshots())

    {:ok,
     socket
     |> assign(search: "", selected: nil, export_text: "")
     |> load_catalog()}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    deck = NetDecking.get_deck(id)
    {:noreply, assign(socket, selected: deck, export_text: export_for(deck))}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, selected: nil, export_text: "")}
  end

  @impl true
  def handle_event("import", %{"import" => params}, socket) do
    case NetDecking.import_decklist(%{
           name: params["name"],
           archetype: params["archetype"],
           source_name: "manual",
           decklist_text: params["decklist_text"] || ""
         }) do
      {:ok, _deck} -> {:noreply, socket |> put_flash(:info, "Deck imported") |> load_catalog()}
      {:error, _changeset} -> {:noreply, put_flash(socket, :error, "Could not import deck")}
    end
  end

  def handle_event("search", %{"value" => query}, socket) do
    {:noreply, assign(socket, search: query)}
  end

  @impl true
  def handle_info({:snapshot_saved, _snapshot}, socket) do
    {:noreply, load_catalog(socket)}
  end

  def handle_info(_message, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app
      flash={@flash}
      catch_up_status={@catch_up_status}
      sidebar_collapsed={@sidebar_collapsed}
      players={@players}
      active_player_id={@active_player_id}
      current_path={@player_scope_uri}
    >
      <div class="flex items-center justify-between mb-6 mt-4">
        <div>
          <.kind_label class="mb-1">netdecking</.kind_label>
          <h1 class="text-2xl font-beleren leading-tight">Standard Netdecks</h1>
        </div>
      </div>

      <form id="netdeck-import" phx-submit="import" class="mb-6 space-y-2">
        <div class="flex gap-2">
          <input
            type="text"
            name="import[name]"
            placeholder="Deck name"
            class="input input-bordered input-sm flex-1"
          />
          <button type="submit" class="btn btn-primary btn-sm">Import</button>
        </div>
        <textarea
          name="import[decklist_text]"
          placeholder="Paste MTGA decklist…"
          rows="4"
          class="textarea textarea-bordered w-full text-sm font-mono"
        ></textarea>
      </form>

      <input
        type="text"
        phx-keyup="search"
        phx-debounce="200"
        value={@search}
        placeholder="Search decks…"
        class="input input-bordered input-sm w-full mb-6"
      />

      <section
        :for={
          {label, key} <- [
            {"Buildable now", :buildable},
            {"Craftable now", :craftable},
            {"Within reach", :short}
          ]
        }
        class="mb-8"
      >
        <h2 class="text-sm font-semibold text-base-content/60 uppercase tracking-wide mb-2">
          {label} ({length(visible(@catalog[key], @search))})
        </h2>
        <ul class="space-y-1">
          <li
            :for={entry <- visible(@catalog[key], @search)}
            class="flex items-baseline gap-3 text-sm"
          >
            <.link patch={~p"/netdecks/#{entry.deck.id}"} class="font-medium hover:underline">
              {entry.deck.name}
            </.link>
            <span :if={entry.deck.archetype} class="text-base-content/50">
              {entry.deck.archetype}
            </span>
            <span class="text-base-content/40">
              {NetdecksHelpers.format_cost(entry.result.maindeck.wildcard_cost)}
            </span>
            <span class="text-base-content/40">
              owned {NetdecksHelpers.format_owned_pct(entry.result.maindeck.owned_pct)}
            </span>
          </li>
        </ul>
        <p :if={visible(@catalog[key], @search) == []} class="text-sm text-base-content/30 italic">
          None
        </p>
      </section>

      <div :if={@selected} class="mt-6 p-4 bg-base-200 rounded-xl">
        <div class="flex items-center justify-between mb-2">
          <h3 class="font-beleren text-lg">{@selected.name}</h3>
          <.link patch={~p"/netdecks"} class="btn btn-ghost btn-xs">Close</.link>
        </div>
        <pre class="text-xs font-mono whitespace-pre-wrap break-all">{@export_text}</pre>
      </div>
    </Layouts.app>
    """
  end

  # ── Private helpers ──────────────────────────────────────────────────────

  defp load_catalog(socket) do
    assign(socket, catalog: NetDecking.catalog())
  end

  defp export_for(nil), do: ""

  defp export_for(deck) do
    main_cards = (deck.main_deck || %{})["cards"] || []
    side_cards = (deck.sideboard || %{})["cards"] || []
    arena_ids = (main_cards ++ side_cards) |> Enum.map(& &1["arena_id"])

    lookup = Cards.list_by_arena_ids(arena_ids)

    MtgaClipboardFormat.format(
      %Deck{current_main_deck: deck.main_deck, current_sideboard: deck.sideboard},
      lookup
    )
  end

  defp visible(entries, search) do
    Enum.filter(entries || [], &NetdecksHelpers.match_search?(&1, search))
  end
end
