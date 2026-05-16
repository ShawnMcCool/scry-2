defmodule Scry2Web.CollectionLive do
  @moduledoc """
  LiveView for the memory-read card collection (ADR 034).

  Reads as a derivation pipeline. After loading the latest
  `Scry2.Collection.Snapshot`, every other section is computed from
  named domain types under `Scry2.Collection.*`:

      snapshot     ← Collection.current()
      cards        ← Cards.list_by_arena_ids(arena_ids)
      rosters      ← Cards.SetRoster.all()
      holdings     ← Holding.from_snapshot(snapshot, cards)
      completions  ← Completion.from_holdings(holdings, rosters)
      craft_plan   ← CraftPlan.from_holdings(holdings, snapshot)
      diffs        ← Collection.list_diffs(limit: 10)

  The view wires those values into focused function components in
  `Scry2Web.Collection.*` — one component per concept, no business logic
  in templates.

  States:

    * **disabled** — `<.disabled_banner>` consent CTA.
    * **enabled, no snapshot** — `<.reader_status>` toolbar + an empty-state.
    * **enabled, with snapshot** — full eight-section pipeline.

  URL filters (decoded by `Scry2Web.CardsHelpers`) round-trip via
  `push_patch`: `q`, `r`, `set`. Selecting a set tile patches `?set=CODE`
  and scopes the holding browser + craft plan to that set.
  """

  use Scry2Web, :live_view

  import Scry2Web.Collection.AcquisitionHistory, only: [acquisition_history: 1]
  import Scry2Web.Collection.Completion, only: [completion: 1]
  import Scry2Web.Collection.CraftPlan, only: [craft_plan: 1]
  import Scry2Web.Collection.DisabledBanner, only: [disabled_banner: 1]
  import Scry2Web.Collection.HoldingBrowser, only: [holding_browser: 1]
  import Scry2Web.Collection.HoldingSummary, only: [holding_summary: 1]
  import Scry2Web.Collection.ReaderStatus, only: [reader_status: 1]
  import Scry2Web.Collection.RecentAcquisitions, only: [recent_acquisitions: 1]
  import Scry2Web.Collection.WildcardSummary, only: [wildcard_summary: 1]

  alias Scry2.Cards
  alias Scry2.Cards.ImageCache
  alias Scry2.Cards.SetRoster
  alias Scry2.Collection
  alias Scry2.Collection.Completion
  alias Scry2.Collection.CraftPlan
  alias Scry2.Collection.Holding
  alias Scry2.Collection.Snapshot
  alias Scry2.Topics
  alias Scry2Web.CardsHelpers

  @browser_limit 100

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Topics.subscribe(Topics.collection_snapshots())
      Topics.subscribe(Topics.collection_diffs())
      Topics.subscribe(Topics.cards_updates())
    end

    socket =
      socket
      |> assign(:reader_enabled, Collection.reader_enabled?())
      |> assign(:refreshing, false)
      |> assign(:last_error, nil)
      |> assign(:build_change_status, Collection.build_change_status())
      |> assign(:search, "")
      |> assign(:filter_rarities, MapSet.new())
      |> assign(:active_set, nil)
      |> assign(:active_set_record, nil)
      |> load_snapshot_state()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(:search, CardsHelpers.decode_search(params))
      |> assign(:filter_rarities, CardsHelpers.decode_rarities(params))
      |> assign(:active_set, normalise_set(params["set"]))
      |> apply_browser_filters()

    {:noreply, socket}
  end

  @impl true
  def handle_event("enable_reader", _params, socket) do
    :ok = Collection.enable_reader!()

    {:noreply,
     socket
     |> assign(:reader_enabled, true)
     |> load_snapshot_state()
     |> apply_browser_filters()}
  end

  def handle_event("disable_reader", _params, socket) do
    :ok = Collection.disable_reader!()

    {:noreply,
     socket
     |> assign(reader_enabled: false, refreshing: false, last_error: nil)
     |> put_flash(:info, "Memory reader disabled.")}
  end

  def handle_event("refresh", _params, socket) do
    case Collection.refresh(trigger: "manual") do
      {:ok, _job} ->
        {:noreply,
         socket
         |> assign(:refreshing, true)
         |> assign(:last_error, nil)
         # Inline-Oban (tests) runs the job synchronously; reload now so
         # the assigns reflect reality. Async-Oban (prod) gets the snapshot
         # via the broadcast handler below.
         |> load_snapshot_state()
         |> apply_browser_filters()
         |> assign(:refreshing, false)}

      {:error, reason} ->
        {:noreply, assign(socket, refreshing: false, last_error: friendly_error(reason))}
    end
  end

  def handle_event("acknowledge_build_change", _params, socket) do
    _ = Collection.acknowledge_current_build!()
    {:noreply, assign(socket, :build_change_status, Collection.build_change_status())}
  end

  def handle_event("search", %{"search" => term}, socket) do
    {:noreply, push_patch(socket, to: build_path(socket, %{"q" => term}))}
  end

  def handle_event("clear_search", _params, socket) do
    {:noreply, push_patch(socket, to: build_path(socket, %{"q" => ""}))}
  end

  def handle_event("toggle_rarity", %{"rarity" => rarity}, socket) do
    rarities = toggle(socket.assigns.filter_rarities, rarity)
    {:noreply, push_patch(socket, to: build_path(socket, %{"r" => encode_set(rarities)}))}
  end

  def handle_event("select_set", %{"set" => code}, socket) do
    new_code = if socket.assigns.active_set == code, do: "", else: code
    {:noreply, push_patch(socket, to: build_path(socket, %{"set" => new_code}))}
  end

  def handle_event("clear_set", _params, socket) do
    {:noreply, push_patch(socket, to: build_path(socket, %{"set" => ""}))}
  end

  @impl true
  def handle_info({:snapshot_saved, _snapshot}, socket) do
    {:noreply,
     socket
     |> assign(:refreshing, false)
     |> assign(:last_error, nil)
     |> assign(:build_change_status, Collection.build_change_status())
     |> load_snapshot_state()
     |> apply_browser_filters()
     |> put_flash(:info, "Collection refreshed.")}
  end

  def handle_info({:diff_saved, _diff}, socket) do
    {:noreply,
     socket
     |> assign(:latest_diff, Collection.latest_diff())
     |> assign(:diff_cards, diff_cards(Collection.latest_diff()))
     |> assign(:recent_diffs, Collection.list_diffs(limit: 10))}
  end

  def handle_info({:refresh_failed, reason}, socket) do
    {:noreply, assign(socket, refreshing: false, last_error: friendly_error(reason))}
  end

  def handle_info({:cards_refreshed, _}, socket) do
    {:noreply,
     socket
     |> load_snapshot_state()
     |> apply_browser_filters()}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # ── Pipeline -------------------------------------------------------------

  defp load_snapshot_state(socket) do
    snapshot = Collection.current()
    rosters = SetRoster.all()
    cards = cards_by_arena_id(snapshot)
    holdings = Holding.from_snapshot(snapshot, cards)

    socket
    |> assign(:snapshot, snapshot)
    |> assign(:cards_by_arena_id, cards)
    |> assign(:set_rosters, rosters)
    |> assign(:holdings, holdings)
    |> assign(:completions, Completion.from_holdings(holdings, rosters))
    |> assign(:craft_plan, build_craft_plan(holdings, snapshot))
    |> assign(:latest_diff, Collection.latest_diff())
    |> assign(:diff_cards, diff_cards(Collection.latest_diff()))
    |> assign(:recent_diffs, Collection.list_diffs(limit: 10))
    |> assign(:cached_arena_ids, cached_set(cards))
  end

  defp apply_browser_filters(socket) do
    holdings = socket.assigns[:holdings] || []
    search = socket.assigns.search
    rarities = socket.assigns.filter_rarities
    rosters = socket.assigns.set_rosters || %{}
    code = socket.assigns.active_set
    set_id = active_set_id(rosters, code)

    filtered =
      holdings
      |> Enum.filter(&matches_search?(&1, search))
      |> Enum.filter(&matches_rarity?(&1, rarities))
      |> Enum.filter(&matches_set?(&1, set_id))
      |> Enum.sort_by(&(&1.card.name || ""))

    visible = Enum.take(filtered, @browser_limit)

    socket
    |> assign(:browser_holdings, visible)
    |> assign(:browser_total, length(filtered))
    |> assign(:active_set_record, active_set_record(rosters, code))
  end

  defp build_craft_plan(_holdings, nil),
    do: %CraftPlan{
      incomplete_playsets: [],
      wildcards_owned: %{"common" => 0, "uncommon" => 0, "rare" => 0, "mythic" => 0},
      wildcards_needed_by_rarity: %{}
    }

  defp build_craft_plan(holdings, snapshot), do: CraftPlan.from_holdings(holdings, snapshot)

  defp cards_by_arena_id(nil), do: %{}

  defp cards_by_arena_id(%Snapshot{cards_json: cards_json}) do
    cards_json
    |> Snapshot.decode_entries()
    |> Enum.map(&elem(&1, 0))
    |> Cards.list_by_arena_ids()
  end

  defp diff_cards(nil), do: %{}

  defp diff_cards(diff) do
    diff
    |> Scry2.Collection.DiffView.arena_ids()
    |> Cards.list_by_arena_ids()
  end

  defp cached_set(cards) when is_map(cards) do
    cards
    |> Map.keys()
    |> Enum.filter(&ImageCache.cached?/1)
    |> MapSet.new()
  end

  # ── Filter helpers -------------------------------------------------------

  defp matches_search?(_holding, ""), do: true

  defp matches_search?(holding, term) when is_binary(term) do
    name = (holding.card.name || "") |> String.downcase()
    String.contains?(name, String.downcase(term))
  end

  defp matches_rarity?(holding, rarities) do
    if MapSet.size(rarities) == 0 do
      true
    else
      MapSet.member?(rarities, holding_rarity(holding))
    end
  end

  defp holding_rarity(holding), do: holding.card.rarity || "unknown"

  defp matches_set?(_holding, nil), do: true
  defp matches_set?(holding, set_id), do: holding.card.set_id == set_id

  defp active_set_id(_rosters, nil), do: nil

  defp active_set_id(rosters, code) when is_binary(code) do
    Enum.find_value(rosters, fn
      {id, %SetRoster{set: %{code: ^code}}} -> id
      _ -> nil
    end)
  end

  defp active_set_record(_rosters, nil), do: nil

  defp active_set_record(rosters, code) when is_binary(code) do
    Enum.find_value(rosters, fn
      {_id, %SetRoster{set: %{code: ^code} = set}} -> set
      _ -> nil
    end)
  end

  defp toggle(set, value) do
    if MapSet.member?(set, value), do: MapSet.delete(set, value), else: MapSet.put(set, value)
  end

  defp encode_set(set) do
    set |> MapSet.to_list() |> Enum.sort() |> Enum.join(",")
  end

  defp normalise_set(nil), do: nil
  defp normalise_set(""), do: nil
  defp normalise_set(code) when is_binary(code), do: code

  defp build_path(socket, overrides) do
    current =
      CardsHelpers.params_from_filters(
        socket.assigns.search,
        MapSet.new(),
        socket.assigns.filter_rarities,
        MapSet.new(),
        MapSet.new()
      )

    set =
      case Map.get(overrides, "set", socket.assigns.active_set) do
        "" -> nil
        nil -> nil
        value -> value
      end

    params =
      current
      |> Map.merge(Map.delete(overrides, "set"))
      |> Map.reject(fn {_k, v} -> v in [nil, ""] end)
      |> maybe_put_set(set)

    "/collection?" <> URI.encode_query(params)
  end

  defp maybe_put_set(params, nil), do: params
  defp maybe_put_set(params, code), do: Map.put(params, "set", code)

  defp friendly_error(:mtga_not_running),
    do: "MTGA is not running. Start the game, then click Refresh now."

  defp friendly_error(:no_cards_array_found),
    do:
      "Could not locate the card collection in MTGA memory. Try again after opening your collection screen in MTGA."

  defp friendly_error({:check, _}),
    do:
      "MTGA memory layout did not match expectations. It may have changed in a recent game update."

  defp friendly_error(other), do: "Reader failed: #{inspect(other)}"

  # ── Render ---------------------------------------------------------------

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
      <h1 class="text-2xl font-semibold mb-6 font-beleren">Collection</h1>

      <%= if @reader_enabled do %>
        <div class="space-y-6" data-role="collection-enabled">
          <.reader_status
            refreshing={@refreshing}
            last_error={@last_error}
            build_change_status={@build_change_status}
          />

          <%= if @snapshot do %>
            <.holding_summary holdings={@holdings} />
            <.wildcard_summary snapshot={@snapshot} />
            <.completion rows={@completions} active_set={@active_set} limit={6} />
            <.recent_acquisitions diff={@latest_diff} cards={@diff_cards} />
            <.holding_browser
              holdings={@browser_holdings}
              total_count={@browser_total}
              search={@search}
              rarities={@filter_rarities}
              active_set={@active_set}
              active_set_record={@active_set_record}
              cached_arena_ids={@cached_arena_ids}
            />
            <.craft_plan value={@craft_plan} cached_arena_ids={@cached_arena_ids} />
            <.acquisition_history diffs={@recent_diffs} />
          <% else %>
            <div
              class="card bg-base-200 border border-base-300 max-w-xl"
              data-role="no-snapshot"
            >
              <div class="card-body">
                <p class="text-sm opacity-80">
                  No snapshot yet. Make sure MTGA is running, then click <strong>Refresh now</strong>.
                </p>
              </div>
            </div>
          <% end %>
        </div>
      <% else %>
        <.disabled_banner />
      <% end %>
    </Layouts.app>
    """
  end
end
