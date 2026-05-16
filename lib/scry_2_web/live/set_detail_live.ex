defmodule Scry2Web.SetDetailLive do
  @moduledoc """
  LiveView for per-set playset completeness drill-in (`/collection/sets/:code`).

  Reads as a derivation pipeline. After looking up the set and the latest
  `Scry2.Collection.Snapshot`, every other section is computed from
  named domain types under `Scry2.Collection.*` and `Scry2.Cards.*`:

      set         ← SetRoster.all() |> find by code
      cards       ← Cards.list_booster_cards_by_set(set.id)
      snapshot    ← Collection.current()
      holdings    ← Holding.from_snapshot(snapshot, snapshot_card_lookup)
      completion  ← SetCompletion.from(set, cards, holdings)

  The view wires those values into the focused function components in
  `Scry2Web.Collection.SetDetail.*` — set picker, summary band, gap list.

  States:

    * **disabled** — `<.disabled_banner>` consent CTA.
    * **enabled, no snapshot** — completion built from an empty holdings
      list; everything in the set falls into the `missing` bucket.
    * **enabled, set not found** — friendly error + link back to overview.
    * **enabled, with snapshot** — full summary + gap list.
  """

  use Scry2Web, :live_view

  import Scry2Web.Collection.DisabledBanner, only: [disabled_banner: 1]
  import Scry2Web.Collection.ReaderStatus, only: [reader_status: 1]
  import Scry2Web.Collection.SetDetail.GapList, only: [gap_list: 1]
  import Scry2Web.Collection.SetDetail.SetPicker, only: [set_picker: 1]
  import Scry2Web.Collection.SetDetail.SetSummary, only: [set_summary: 1]

  alias Scry2.Cards
  alias Scry2.Cards.ImageCache
  alias Scry2.Cards.Set
  alias Scry2.Cards.SetRoster
  alias Scry2.Collection
  alias Scry2.Collection.Holding
  alias Scry2.Collection.SetCompletion
  alias Scry2.Collection.Snapshot
  alias Scry2.Topics

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
      |> assign(:active_code, nil)
      |> assign(:set, nil)
      |> assign(:sets, [])
      |> assign(:snapshot, nil)
      |> assign(:completion, nil)
      |> assign(:cached_arena_ids, MapSet.new())

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"code" => code}, _uri, socket) do
    {:noreply, socket |> assign(:active_code, code) |> load_state()}
  end

  @impl true
  def handle_event("pick_set", %{"code" => code}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/collection/sets/#{code}")}
  end

  def handle_event("enable_reader", _params, socket) do
    :ok = Collection.enable_reader!()

    {:noreply,
     socket
     |> assign(:reader_enabled, true)
     |> load_state()}
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
         |> load_state()
         |> assign(:refreshing, false)}

      {:error, reason} ->
        {:noreply, assign(socket, refreshing: false, last_error: friendly_error(reason))}
    end
  end

  def handle_event("acknowledge_build_change", _params, socket) do
    _ = Collection.acknowledge_current_build!()
    {:noreply, assign(socket, :build_change_status, Collection.build_change_status())}
  end

  @impl true
  def handle_info({:snapshot_saved, _snapshot}, socket) do
    {:noreply,
     socket
     |> assign(:refreshing, false)
     |> assign(:last_error, nil)
     |> assign(:build_change_status, Collection.build_change_status())
     |> load_state()
     |> put_flash(:info, "Collection refreshed.")}
  end

  def handle_info({:diff_saved, _diff}, socket), do: {:noreply, load_state(socket)}

  def handle_info({:refresh_failed, reason}, socket) do
    {:noreply, assign(socket, refreshing: false, last_error: friendly_error(reason))}
  end

  def handle_info({:cards_refreshed, _}, socket), do: {:noreply, load_state(socket)}

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:cache_images, _result, socket) do
    rendered = rendered_arena_ids(socket.assigns.completion)
    cached = rendered |> Enum.filter(&ImageCache.cached?/1) |> MapSet.new()
    {:noreply, assign(socket, :cached_arena_ids, cached)}
  end

  # ── Pipeline -------------------------------------------------------------

  defp load_state(socket) do
    rosters = SetRoster.all()
    sets = sets_in_display_order(rosters)

    case find_set(rosters, socket.assigns.active_code) do
      nil ->
        socket
        |> assign(:sets, sets)
        |> assign(:set, nil)
        |> assign(:snapshot, nil)
        |> assign(:completion, nil)
        |> assign(:cached_arena_ids, MapSet.new())

      set ->
        snapshot = Collection.current()
        cards_in_set = Cards.list_booster_cards_by_set(set.id)
        holdings = build_holdings(snapshot)
        completion = SetCompletion.from(set, cards_in_set, holdings)
        rendered = rendered_arena_ids(completion)
        cached = rendered |> Enum.filter(&ImageCache.cached?/1) |> MapSet.new()

        socket
        |> assign(:sets, sets)
        |> assign(:set, set)
        |> assign(:snapshot, snapshot)
        |> assign(:completion, completion)
        |> assign(:cached_arena_ids, cached)
        |> maybe_cache_images(rendered)
    end
  end

  defp build_holdings(nil), do: []

  defp build_holdings(%Snapshot{cards_json: cards_json} = snapshot) when is_binary(cards_json) do
    arena_ids =
      cards_json
      |> Snapshot.decode_entries()
      |> Enum.map(&elem(&1, 0))

    cards_lookup = Cards.list_by_arena_ids(arena_ids)
    Holding.from_snapshot(snapshot, cards_lookup)
  end

  defp build_holdings(%Snapshot{}), do: []

  defp rendered_arena_ids(nil), do: []

  defp rendered_arena_ids(%SetCompletion{buckets: buckets}) do
    (buckets.missing ++ buckets.partial)
    |> Enum.map(fn {card, _count} -> card.arena_id end)
  end

  defp maybe_cache_images(socket, []), do: socket

  defp maybe_cache_images(socket, ids) do
    start_async(socket, :cache_images, fn -> ImageCache.ensure_cached(ids) end)
  end

  defp sets_in_display_order(rosters) do
    rosters
    |> Map.values()
    |> Enum.map(& &1.set)
    |> Enum.sort_by(&set_sort_key/1, :desc)
  end

  # Same chronological-then-code sort as `Scry2.Collection.Completion`,
  # so the picker order matches the overview tile order on `/collection`.
  defp set_sort_key(%Set{released_at: nil, code: code}), do: {0, {0, 0, 0}, code}
  defp set_sort_key(%Set{released_at: date, code: code}), do: {1, Date.to_erl(date), code}

  defp find_set(rosters, code) when is_binary(code) do
    Enum.find_value(rosters, fn
      {_id, %SetRoster{set: %Set{code: ^code} = set}} -> set
      _ -> nil
    end)
  end

  defp find_set(_rosters, _code), do: nil

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
      <div class="flex items-center justify-between gap-3 mb-6">
        <div>
          <.link navigate={~p"/collection"} class="text-xs link link-hover text-base-content/60">
            ← Collection
          </.link>
          <h1 class="text-2xl font-semibold font-beleren mt-1">
            {set_title(@set)}
          </h1>
          <p :if={@set && @set.released_at} class="text-xs text-base-content/60">
            Released {Calendar.strftime(@set.released_at, "%Y-%m-%d")}
          </p>
        </div>

        <.set_picker :if={@sets != []} sets={@sets} active_code={@active_code || ""} />
      </div>

      <%= cond do %>
        <% not @reader_enabled -> %>
          <.disabled_banner />
        <% is_nil(@set) -> %>
          <div class="card bg-base-200 border border-base-300 max-w-xl" data-role="set-not-found">
            <div class="card-body space-y-3">
              <h2 class="card-title">Set not found</h2>
              <p class="text-sm opacity-80">
                No set with code <strong>{@active_code}</strong>
                is in your card database. The set may not have been imported yet.
              </p>
              <.link navigate={~p"/collection"} class="link link-primary text-sm">
                ← Back to Collection
              </.link>
            </div>
          </div>
        <% true -> %>
          <div class="space-y-6" data-role="set-detail">
            <.reader_status
              refreshing={@refreshing}
              last_error={@last_error}
              build_change_status={@build_change_status}
            />

            <%= if is_nil(@snapshot) do %>
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
            <% else %>
              <.set_summary completion={@completion} />
              <.gap_list completion={@completion} cached_arena_ids={@cached_arena_ids} />
            <% end %>
          </div>
      <% end %>
    </Layouts.app>
    """
  end

  defp set_title(nil), do: "Set"
  defp set_title(%Set{name: name, code: code}), do: "#{name} (#{code})"
end
