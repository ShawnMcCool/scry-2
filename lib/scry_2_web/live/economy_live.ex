defmodule Scry2Web.EconomyLive do
  @moduledoc """
  LiveView for economy tracking — event ROI, inventory balances,
  resource transactions, and time-series charts for currency and wildcards.
  """
  use Scry2Web, :live_view

  alias Scry2.Economy
  alias Scry2.Topics
  alias Scry2Web.EconomyHelpers

  @valid_ranges ~w(today week season)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Topics.subscribe(Topics.economy_updates())

    {:ok,
     assign(socket,
       entries: [],
       inventory: nil,
       snapshots: [],
       time_range: "week",
       currency_series: "{}",
       wildcards_series: "{}",
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

  def handle_info(:reload_data, socket) do
    {:noreply, load_data(socket) |> assign(:reload_timer, nil)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp load_data(socket) do
    player_id = socket.assigns[:active_player_id]

    socket
    |> assign(
      entries: Economy.list_event_entries(player_id: player_id),
      inventory: Economy.latest_inventory(player_id: player_id),
      snapshots: Economy.list_inventory_snapshots(player_id: player_id)
    )
    |> build_chart_assigns()
  end

  defp build_chart_assigns(socket) do
    filtered =
      EconomyHelpers.filter_snapshots_to_range(
        socket.assigns.snapshots,
        socket.assigns.time_range
      )

    assign(socket,
      currency_series: Jason.encode!(EconomyHelpers.currency_series(filtered)),
      wildcards_series: Jason.encode!(EconomyHelpers.wildcards_series(filtered))
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app flash={@flash} players={@players} active_player_id={@active_player_id}>
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
          <.stat_card title="Common" value={@inventory.wildcards_common || 0}>
            <:icon><.wildcard_icon rarity="common" /></:icon>
          </.stat_card>
          <.stat_card title="Uncommon" value={@inventory.wildcards_uncommon || 0}>
            <:icon><.wildcard_icon rarity="uncommon" /></:icon>
          </.stat_card>
          <.stat_card title="Rare" value={@inventory.wildcards_rare || 0}>
            <:icon><.wildcard_icon rarity="rare" /></:icon>
          </.stat_card>
          <.stat_card title="Mythic" value={@inventory.wildcards_mythic || 0}>
            <:icon><.wildcard_icon rarity="mythic" /></:icon>
          </.stat_card>
          <.stat_card
            title="Vault"
            value={"#{Float.round((@inventory.vault_progress || 0) / 1, 1)}%"}
          />
        </div>

        <%!-- Charts --%>
        <section :if={length(@snapshots) >= 2} class="space-y-4">
          <div class="flex items-center gap-2">
            <div class="join">
              <button
                :for={range <- ~w(today week season)}
                phx-click="change_range"
                phx-value-range={range}
                class={[
                  "join-item btn btn-sm",
                  if(@time_range == range, do: "btn-active", else: "btn-ghost")
                ]}
              >
                {String.capitalize(range)}
              </button>
            </div>
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
                    <div class="font-medium">{entry.event_type || entry.event_name}</div>
                    <div :if={entry.set_code} class="text-xs text-base-content/40">
                      {entry.set_code}
                    </div>
                  </td>
                  <td class="text-right tabular-nums">
                    {EconomyHelpers.format_currency(entry.entry_fee, entry.entry_currency_type || "")}
                  </td>
                  <td class="text-right tabular-nums">
                    {if entry.final_wins, do: "#{entry.final_wins}–#{entry.final_losses}", else: "—"}
                  </td>
                  <td class="text-right tabular-nums">
                    {format_prizes(entry)}
                  </td>
                  <td class={[
                    "text-right tabular-nums font-medium",
                    EconomyHelpers.roi_color_class(entry)
                  ]}>
                    {EconomyHelpers.format_roi(entry)}
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

  defp format_prizes(%{gems_awarded: gems, gold_awarded: gold}) do
    parts =
      [
        if(gems && gems > 0, do: EconomyHelpers.format_number(gems) <> " Gems"),
        if(gold && gold > 0, do: EconomyHelpers.format_number(gold) <> " Gold")
      ]
      |> Enum.reject(&is_nil/1)

    if parts == [], do: "—", else: Enum.join(parts, ", ")
  end

  defp format_prizes(_), do: "—"
end
