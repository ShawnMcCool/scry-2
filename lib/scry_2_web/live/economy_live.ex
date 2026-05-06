defmodule Scry2Web.EconomyLive do
  @moduledoc """
  LiveView for economy tracking — event ROI, inventory balances,
  resource transactions, and time-series charts for currency and wildcards.
  """
  use Scry2Web, :live_view

  alias Scry2.Cards
  alias Scry2.Collection
  alias Scry2.Collection.PendingPacks
  alias Scry2.Crafts
  alias Scry2.Economy
  alias Scry2.Economy.Forecast
  alias Scry2.MtgaEvents
  alias Scry2.Topics
  alias Scry2Web.EconomyHelpers

  import Scry2Web.RecentCraftsCard
  import Scry2Web.Components.RecentCardGrantsCard
  import Scry2Web.Components.PendingPacksCard
  import Scry2Web.Components.ForecastStrip
  import Scry2Web.Components.MasteryCard
  import Scry2Web.Components.ActiveEventsCard

  @valid_ranges ~w(today 3d week 2w season)
  @default_range "2w"
  @recent_crafts_limit 25
  @recent_card_grants_limit 25

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Topics.subscribe(Topics.economy_updates())
      Topics.subscribe(Topics.crafts_updates())
      Topics.subscribe(Topics.collection_snapshots())
    end

    {:ok,
     assign(socket,
       entries: [],
       inventory: nil,
       snapshots: [],
       crafts: [],
       crafts_cards_by_arena_id: %{},
       card_grants: [],
       grants_cards_by_arena_id: %{},
       pending_packs: [],
       latest_snapshot: nil,
       collection_snapshots: [],
       mastery_forecast: nil,
       active_events: [],
       active_events_error: nil,
       time_range: @default_range,
       currency_series: "{}",
       wildcards_series: "{}",
       forecast_visible: false,
       gold_net: 0,
       gold_rate: 0.0,
       gems_net: 0,
       gems_rate: 0.0,
       vault_eta: :insufficient_data,
       reload_timer: nil
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) when range in @valid_ranges do
    {:noreply,
     socket
     |> assign(:time_range, range)
     |> build_chart_assigns()}
  end

  @impl true
  def handle_info({:economy_updated, _}, socket) do
    {:noreply, schedule_reload(socket)}
  end

  def handle_info({:crafts_recorded, _}, socket) do
    {:noreply, schedule_reload(socket)}
  end

  def handle_info({:snapshot_saved, _}, socket) do
    {:noreply, schedule_reload(socket)}
  end

  def handle_info(:reload_data, socket) do
    {:noreply, load_data(socket) |> assign(:reload_timer, nil)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp load_data(socket) do
    player_id = socket.assigns[:active_player_id]

    crafts = Crafts.list_recent(limit: @recent_crafts_limit)
    crafts_cards = load_crafts_cards(crafts)

    card_grants = Economy.list_card_grants(limit: @recent_card_grants_limit)
    grants_cards = load_grants_cards(card_grants)

    latest_snapshot = Collection.current()
    collection_snapshots = Collection.list_snapshots(limit: 200) |> Enum.reverse()

    mastery_forecast =
      Forecast.mastery_eta(mastery_inputs(collection_snapshots), DateTime.utc_now())

    {active_events, active_events_error} = read_active_events_safely()

    socket
    |> assign(
      entries: Economy.list_event_entries(player_id: player_id),
      inventory: Economy.latest_inventory(player_id: player_id),
      snapshots: Economy.list_inventory_snapshots(player_id: player_id),
      crafts: crafts,
      crafts_cards_by_arena_id: crafts_cards,
      card_grants: card_grants,
      grants_cards_by_arena_id: grants_cards,
      pending_packs: PendingPacks.summarize(latest_snapshot),
      latest_snapshot: latest_snapshot,
      collection_snapshots: collection_snapshots,
      mastery_forecast: mastery_forecast,
      active_events: active_events,
      active_events_error: active_events_error
    )
    |> build_chart_assigns()
  end

  defp mastery_inputs(snapshots) do
    Enum.map(snapshots, fn s ->
      %{
        occurred_at: s.snapshot_ts,
        mastery_tier: s.mastery_tier,
        mastery_xp_in_tier: s.mastery_xp_in_tier,
        mastery_season_ends_at: s.mastery_season_ends_at
      }
    end)
  end

  defp read_active_events_safely do
    case MtgaEvents.read_active_events() do
      {:ok, records} -> {records, nil}
      {:error, reason} -> {[], reason}
    end
  rescue
    _ -> {[], :read_failed}
  end

  defp load_crafts_cards([]), do: %{}

  defp load_crafts_cards(crafts) do
    arena_ids = Enum.map(crafts, & &1.arena_id) |> Enum.uniq()
    Cards.list_by_arena_ids(arena_ids)
  end

  defp load_grants_cards([]), do: %{}

  defp load_grants_cards(grants) do
    arena_ids =
      grants
      |> Enum.flat_map(fn grant ->
        grant.cards
        |> Scry2.Economy.CardGrant.unwrap_cards()
        |> Enum.map(fn row -> row["arena_id"] || row[:arena_id] end)
      end)
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()

    Cards.list_by_arena_ids(arena_ids)
  end

  defp build_chart_assigns(socket) do
    filtered =
      EconomyHelpers.filter_snapshots_to_range(
        socket.assigns.snapshots,
        socket.assigns.time_range
      )

    assign(socket,
      currency_series: Jason.encode!(EconomyHelpers.currency_series(filtered)),
      wildcards_series: Jason.encode!(EconomyHelpers.wildcards_series(filtered)),
      forecast_visible: length(filtered) >= 2,
      gold_net: Forecast.net_change(filtered, :gold),
      gold_rate: Forecast.daily_rate(filtered, :gold),
      gems_net: Forecast.net_change(filtered, :gems),
      gems_rate: Forecast.daily_rate(filtered, :gems),
      vault_eta: Forecast.vault_eta(filtered, DateTime.utc_now())
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app
      flash={@flash}
      players={@players}
      active_player_id={@active_player_id}
      current_path={@player_scope_uri}
    >
      <h1 class="text-2xl font-semibold mb-6 font-beleren">Economy</h1>

      <.empty_state :if={is_nil(@inventory) and @entries == []}>
        No economy data yet. Join an event or play a match to start tracking.
      </.empty_state>

      <div
        :if={@inventory || @entries != []}
        class="space-y-8"
      >
        <%!-- Current balance cards --%>
        <div :if={@inventory} class="grid grid-cols-2 md:grid-cols-4 lg:grid-cols-7 gap-4">
          <.stat_card title="Gold" value={EconomyHelpers.format_number(@inventory.gold || 0)}>
            <:icon><img src={~p"/images/coin.png"} class="size-5" alt="Gold" /></:icon>
          </.stat_card>
          <.stat_card title="Gems" value={EconomyHelpers.format_number(@inventory.gems || 0)}>
            <:icon><img src={~p"/images/gem.png"} class="size-5" alt="Gems" /></:icon>
          </.stat_card>
          <.stat_card
            title="Common"
            value={@inventory.wildcards_common || 0}
            class={EconomyHelpers.wildcard_class(@inventory, :common)}
          >
            <:icon><.wildcard_icon rarity="common" /></:icon>
          </.stat_card>
          <.stat_card
            title="Uncommon"
            value={@inventory.wildcards_uncommon || 0}
            class={EconomyHelpers.wildcard_class(@inventory, :uncommon)}
          >
            <:icon><.wildcard_icon rarity="uncommon" /></:icon>
          </.stat_card>
          <.stat_card
            title="Rare"
            value={@inventory.wildcards_rare || 0}
            class={EconomyHelpers.wildcard_class(@inventory, :rare)}
          >
            <:icon><.wildcard_icon rarity="rare" /></:icon>
          </.stat_card>
          <.stat_card
            title="Mythic"
            value={@inventory.wildcards_mythic || 0}
            class={EconomyHelpers.wildcard_class(@inventory, :mythic)}
          >
            <:icon><.wildcard_icon rarity="mythic" /></:icon>
          </.stat_card>
          <.stat_card
            title="Vault"
            value={"#{Float.round((@inventory.vault_progress || 0.0), 1)}%"}
          >
            <:icon><.icon name="hero-archive-box-solid" class="size-5 text-warning" /></:icon>
          </.stat_card>
        </div>

        <%!-- Charts --%>
        <section :if={length(@snapshots) >= 2} class="space-y-4">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <div class="join">
              <button
                :for={
                  {range, label} <- [
                    {"today", "Today"},
                    {"3d", "Past 3D"},
                    {"week", "Past Week"},
                    {"2w", "Past 2W"},
                    {"season", "Season"}
                  ]
                }
                phx-click="change_range"
                phx-value-range={range}
                class={[
                  "join-item btn btn-sm",
                  if(@time_range == range, do: "btn-active", else: "btn-ghost")
                ]}
              >
                {label}
              </button>
            </div>

            <.forecast_strip
              gold_net={@gold_net}
              gold_rate={@gold_rate}
              gems_net={@gems_net}
              gems_rate={@gems_rate}
              vault_eta={@vault_eta}
              visible={@forecast_visible}
            />
          </div>

          <div>
            <p class="text-xs text-base-content/40 mb-1 uppercase tracking-wide">
              Currency Over Time
            </p>
            <div
              id="chart-economy-currency"
              phx-hook="Chart"
              data-chart-type="economy_currency"
              data-series={@currency_series}
              class="w-full rounded-lg bg-base-200"
              style="height: 15rem"
            />
          </div>

          <div>
            <p class="text-xs text-base-content/40 mb-1 uppercase tracking-wide">
              Wildcards Over Time
            </p>
            <div
              id="chart-economy-wildcards"
              phx-hook="Chart"
              data-chart-type="economy_wildcards"
              data-series={@wildcards_series}
              class="w-full rounded-lg bg-base-200"
              style="height: 15rem"
            />
          </div>
        </section>

        <%!-- Mastery Pass card (memory-read snapshot) --%>
        <.mastery_card snapshot={@latest_snapshot} forecast={@mastery_forecast} />

        <%!-- Active events card (memory-read, Chain 3) --%>
        <.active_events_card records={@active_events} error={@active_events_error} />

        <%!-- Pending booster inventory by set --%>
        <.pending_packs_card rows={@pending_packs} />

        <%!-- Recent crafts (ADR-037) --%>
        <.recent_crafts_card crafts={@crafts} cards_by_arena_id={@crafts_cards_by_arena_id} />

        <%!-- Recent card grants from MTGA event log --%>
        <.recent_card_grants_card
          grants={@card_grants}
          cards_by_arena_id={@grants_cards_by_arena_id}
        />

        <%!-- Event history --%>
        <section :if={@entries != []}>
          <h2 class="text-lg font-semibold mb-3 font-beleren">Event History</h2>
          <div class="overflow-x-auto rounded-lg border border-base-content/5">
            <table class="table table-sm">
              <thead>
                <tr class="text-xs uppercase tracking-wide text-base-content/40">
                  <th>Event</th>
                  <th class="text-right">Entry</th>
                  <th class="text-right">Record</th>
                  <th class="text-right">Prizes</th>
                  <th class="text-right">Net</th>
                  <th class="text-right">Date</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={entry <- @entries} class="hover">
                  <td>
                    <div class="flex items-center gap-2 font-medium">
                      <.set_icon
                        :if={entry.set_code}
                        code={entry.set_code}
                        class="text-base-content/60"
                      />
                      {entry.event_type || entry.event_name}
                    </div>
                  </td>
                  <td class="text-right tabular-nums">
                    <span :if={entry.entry_fee} class="inline-flex items-center gap-1">
                      {EconomyHelpers.format_number(entry.entry_fee)}
                      <.currency_icon
                        :if={entry.entry_currency_type}
                        type={entry.entry_currency_type}
                      />
                    </span>
                    <span :if={!entry.entry_fee}>—</span>
                  </td>
                  <td class="text-right tabular-nums">
                    {if entry.final_wins, do: "#{entry.final_wins}–#{entry.final_losses}", else: "—"}
                  </td>
                  <td class="text-right tabular-nums">
                    <%= case prize_parts(entry) do %>
                      <% [] -> %>
                        —
                      <% parts -> %>
                        <%= for {{amount, currency_type}, index} <- Enum.with_index(parts) do %>
                          <span :if={index > 0} class="text-base-content/30">, </span><span class="inline-flex items-center gap-1">{amount} <.currency_icon type={
                            currency_type
                          } /></span>
                        <% end %>
                    <% end %>
                  </td>
                  <td class="text-right tabular-nums font-medium">
                    <%= for {{text, currency_type, color}, index} <- Enum.with_index(EconomyHelpers.roi_parts(entry)) do %>
                      <span :if={index > 0} class="text-base-content/30">, </span><span class={[
                        "inline-flex items-center gap-1",
                        color
                      ]}>{text} <.currency_icon :if={currency_type} type={currency_type} /></span>
                    <% end %>
                  </td>
                  <td class="text-right tabular-nums text-base-content/50">
                    {EconomyHelpers.format_short_date(entry.joined_at)}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp prize_parts(%{gems_awarded: gems, gold_awarded: gold}) do
    [
      if(gems && gems > 0, do: {EconomyHelpers.format_number(gems), "Gems"}),
      if(gold && gold > 0, do: {EconomyHelpers.format_number(gold), "Gold"})
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp prize_parts(_), do: []
end
