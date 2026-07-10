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
  alias Scry2.Cards.SetRoster
  alias Scry2.Collection
  alias Scry2.Collection.BuildChange
  alias Scry2.Collection.Completion
  alias Scry2.Collection.CraftPlan
  alias Scry2.Collection.Holding
  alias Scry2.Collection.ReaderHealth
  alias Scry2.Collection.Snapshot
  alias Scry2Web.CardImages
  alias Scry2Web.Collection.BuildChangeBanner
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
      |> assign(:reader_enabled, false)
      |> assign(:refreshing, false)
      |> assign(:last_error, nil)
      |> assign(:build_change_status, :unknown)
      |> assign(:verify_state, :idle)
      |> assign(:verify_detail, nil)
      |> assign(:verify_attempt_hint, nil)
      |> assign(:reader_health, initial_reader_health())
      |> assign(:search, "")
      |> assign(:filter_rarities, MapSet.new())
      |> assign(:active_set, nil)
      |> assign(:active_set_record, nil)
      |> assign(:snapshot, nil)
      |> assign(:cards_by_arena_id, %{})
      |> assign(:set_rosters, %{})
      |> assign(:holdings, [])
      |> assign(:completions, [])
      |> assign(:craft_plan, empty_craft_plan())
      |> assign(:latest_diff, nil)
      |> assign(:diff_cards, %{})
      |> assign(:recent_diffs, [])
      |> assign(:cached_card_ids, CardImages.empty())
      |> assign(:browser_holdings, [])
      |> assign(:browser_total, 0)
      |> assign(:loaded, false)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # Defer the snapshot/cards/rosters fan-out from mount to handle_params
    # so the dead render returns quickly; load once per page open and
    # reuse the cache across push_patch chip clicks.
    socket =
      if socket.assigns.loaded do
        socket
      else
        socket
        |> assign(:reader_enabled, Collection.reader_enabled?())
        |> assign(:build_change_status, Collection.build_change_status())
        |> load_snapshot_state()
        |> recompute_reader_health()
        |> recompute_verify_state()
        |> assign(:loaded, true)
      end

    socket =
      socket
      |> assign(:search, CardsHelpers.decode_search(params))
      |> assign(:filter_rarities, CardsHelpers.decode_rarities(params))
      |> assign(:active_set, normalise_set(params["set"]))
      |> apply_browser_filters()

    {:noreply, socket}
  end

  defp empty_craft_plan do
    %CraftPlan{
      incomplete_playsets: [],
      wildcards_owned: %{"common" => 0, "uncommon" => 0, "rare" => 0, "mythic" => 0},
      wildcards_needed_by_rarity: %{}
    }
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

    {:noreply,
     socket
     |> assign(:build_change_status, Collection.build_change_status())
     |> reset_verify_state()}
  end

  def handle_event("verify_build_change", _params, socket) do
    case Collection.refresh(trigger: "verify_build_change") do
      {:ok, _job} ->
        Process.send_after(self(), :verify_timeout, 30_000)

        socket =
          socket
          |> assign(:verify_state, :running)
          |> assign(:verify_detail, nil)
          |> assign(:verify_attempt_hint, current_hint(socket.assigns.build_change_status))
          # Inline-Oban (tests) ran the job synchronously above — reload snapshot
          # state now and classify so the test can observe the post-verify state
          # without round-tripping through PubSub.
          |> load_snapshot_state()
          |> recompute_reader_health()

        {:noreply, classify_verify_result(socket)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:verify_state, :failed)
         |> assign(:verify_detail, BuildChangeBanner.translate_error(reason))}
    end
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
    socket =
      socket
      |> assign(:refreshing, false)
      |> assign(:last_error, nil)
      |> assign(:build_change_status, Collection.build_change_status())
      |> load_snapshot_state()
      |> apply_browser_filters()
      |> recompute_reader_health()
      |> classify_verify_result()

    {:noreply, put_flash(socket, :info, "Collection refreshed.")}
  end

  def handle_info({:diff_saved, _diff}, socket) do
    {:noreply,
     socket
     |> assign(:latest_diff, Collection.latest_diff())
     |> assign(:diff_cards, diff_cards(Collection.latest_diff()))
     |> assign(:recent_diffs, Collection.list_diffs(limit: 10))}
  end

  def handle_info({:refresh_failed, reason}, socket) do
    socket =
      socket
      |> assign(refreshing: false, last_error: friendly_error(reason))
      |> recompute_reader_health()
      |> maybe_classify_verify_failure(reason)

    {:noreply, socket}
  end

  def handle_info(:verify_timeout, socket) do
    case socket.assigns.verify_state do
      :running ->
        {:noreply,
         socket
         |> assign(:verify_state, :failed)
         |> assign(
           :verify_detail,
           "Verification took longer than expected — check Diagnostics for details"
         )}

      _ ->
        {:noreply, socket}
    end
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
    |> cache_rendered_images()
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

  @doc """
  Arena ids whose images are actually rendered on the page — the visible
  browser holdings plus the craft-plan playset cards, de-duplicated. This
  is the bounded set `ensure_cached/2` fetches (the full collection can be
  thousands of cards; only the visible slice needs images now).
  """
  @spec rendered_arena_ids([Holding.t()], CraftPlan.t()) :: [integer()]
  def rendered_arena_ids(browser_holdings, %CraftPlan{incomplete_playsets: rows}) do
    browser = Enum.map(browser_holdings, & &1.arena_id)
    craft = Enum.map(rows, & &1.holding.arena_id)
    Enum.uniq(browser ++ craft)
  end

  defp cache_rendered_images(socket) do
    ids = rendered_arena_ids(socket.assigns.browser_holdings, socket.assigns.craft_plan)
    CardImages.request(socket, ids)
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

  # ── Reader-health + build-change verification helpers ─────────────────

  defp initial_reader_health do
    ReaderHealth.compute(snapshot: nil, reader_enabled: false)
  end

  defp recompute_reader_health(socket) do
    health =
      ReaderHealth.compute(
        snapshot: socket.assigns[:snapshot],
        reader_enabled: socket.assigns[:reader_enabled]
      )

    assign(socket, :reader_health, health)
  end

  defp recompute_verify_state(socket) do
    case BuildChange.verification_state(
           socket.assigns[:snapshot],
           socket.assigns[:build_change_status]
         ) do
      :already_verified ->
        socket
        |> assign(:verify_state, :ok)
        |> assign(:verify_detail, nil)

      :unverified ->
        socket
    end
  end

  defp reset_verify_state(socket) do
    socket
    |> assign(:verify_state, :idle)
    |> assign(:verify_detail, nil)
    |> assign(:verify_attempt_hint, nil)
  end

  defp current_hint({:changed, _prev, current}), do: current
  defp current_hint(_), do: nil

  # Classify the post-refresh state when a verify attempt is in flight.
  # Inspects the latest snapshot's reader_confidence + mtga_build_hint and
  # promotes :running → :ok | :fallback. Failures arrive via :refresh_failed.
  defp classify_verify_result(socket) do
    case socket.assigns[:verify_state] do
      :running -> classify_running_verify(socket)
      _ -> socket
    end
  end

  defp classify_running_verify(socket) do
    snapshot = socket.assigns[:snapshot]
    attempt_hint = socket.assigns[:verify_attempt_hint]

    cond do
      is_nil(snapshot) ->
        socket

      snapshot.reader_confidence == "walker" and
          (is_nil(attempt_hint) or snapshot.mtga_build_hint == attempt_hint) ->
        socket
        |> assign(:verify_state, :ok)
        |> assign(:verify_detail, nil)

      snapshot.reader_confidence == "fallback_scan" ->
        socket
        |> assign(:verify_state, :fallback)
        |> assign(:verify_detail, nil)

      true ->
        socket
    end
  end

  defp maybe_classify_verify_failure(socket, reason) do
    case socket.assigns[:verify_state] do
      :running ->
        state =
          case reason do
            :mtga_not_running -> :mtga_not_running
            _ -> :failed
          end

        socket
        |> assign(:verify_state, state)
        |> assign(:verify_detail, BuildChangeBanner.translate_error(reason))

      _ ->
        socket
    end
  end

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
            health={@reader_health}
            verify_state={@verify_state}
            verify_detail={@verify_detail}
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
              cached_ids={@cached_card_ids}
            />
            <.craft_plan value={@craft_plan} cached_ids={@cached_card_ids} />
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
