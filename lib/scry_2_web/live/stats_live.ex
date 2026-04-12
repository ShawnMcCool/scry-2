defmodule Scry2Web.StatsLive do
  @moduledoc """
  LiveView for aggregate match statistics.

  Queries the `Matches` context for win rates, format breakdowns, and
  deck color breakdowns. All data is precomputed in the projection —
  this page only aggregates via SQL GROUP BY.
  """
  use Scry2Web, :live_view

  alias Scry2.Matches
  alias Scry2.Mulligans
  alias Scry2.Topics
  alias Scry2Web.StatsHelpers

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Topics.subscribe(Topics.matches_updates())

    {:ok, assign(socket, stats: nil, reload_timer: nil)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    player_id = socket.assigns[:active_player_id]
    stats = Matches.aggregate_stats(player_id: player_id)
    mulligan_stats = Mulligans.mulligan_analytics(player_id: player_id)
    {:noreply, assign(socket, stats: stats, mulligan_stats: mulligan_stats)}
  end

  @impl true
  def handle_info({:match_updated, _}, socket) do
    {:noreply, schedule_reload(socket)}
  end

  def handle_info(:reload_data, socket) do
    player_id = socket.assigns[:active_player_id]
    stats = Matches.aggregate_stats(player_id: player_id)
    mulligan_stats = Mulligans.mulligan_analytics(player_id: player_id)
    {:noreply, assign(socket, stats: stats, mulligan_stats: mulligan_stats, reload_timer: nil)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app flash={@flash} players={@players} active_player_id={@active_player_id}>
      <h1 class="text-2xl font-semibold mb-6 font-beleren">Stats</h1>

      <.empty_state :if={@stats.total == 0}>
        No completed matches yet. Play some games to see statistics here.
      </.empty_state>

      <div :if={@stats.total > 0} class="space-y-8">
        <%!-- Overall stat cards --%>
        <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-4">
          <.stat_card title="Matches" value={@stats.total} />
          <.stat_card title="Record" value={StatsHelpers.record(@stats.wins, @stats.losses)} />
          <.stat_card
            title="Win Rate"
            value={StatsHelpers.format_win_rate(@stats.win_rate)}
            class={StatsHelpers.win_rate_class(@stats.win_rate)}
          />
          <.stat_card title="Wins" value={@stats.wins} class="text-emerald-400" />
          <.stat_card title="Avg Turns" value={StatsHelpers.format_avg(@stats.avg_turns)} />
          <.stat_card
            title="Avg Mulligans"
            value={StatsHelpers.format_avg(@stats.avg_mulligans)}
          />
        </div>

        <%!-- By format breakdown --%>
        <section :if={@stats.by_format != []}>
          <h2 class="text-lg font-semibold mb-3 font-beleren">By Format</h2>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Format</th>
                  <th class="text-right">Matches</th>
                  <th class="text-right">Record</th>
                  <th class="text-right">Win Rate</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @stats.by_format}>
                  <td>{format_label(row.key)}</td>
                  <td class="text-right tabular-nums">{row.total}</td>
                  <td class="text-right tabular-nums">
                    {StatsHelpers.record(row.wins, row.losses)}
                  </td>
                  <td class={["text-right tabular-nums", StatsHelpers.win_rate_class(row.win_rate)]}>
                    {StatsHelpers.format_win_rate(row.win_rate)}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <%!-- By deck colors breakdown --%>
        <section :if={@stats.by_deck_colors != []}>
          <h2 class="text-lg font-semibold mb-3 font-beleren">By Deck Colors</h2>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Colors</th>
                  <th class="text-right">Matches</th>
                  <th class="text-right">Record</th>
                  <th class="text-right">Win Rate</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @stats.by_deck_colors}>
                  <td>
                    <span class="flex gap-0.5">
                      <.mana_pips colors={row.key} />
                    </span>
                  </td>
                  <td class="text-right tabular-nums">{row.total}</td>
                  <td class="text-right tabular-nums">
                    {StatsHelpers.record(row.wins, row.losses)}
                  </td>
                  <td class={["text-right tabular-nums", StatsHelpers.win_rate_class(row.win_rate)]}>
                    {StatsHelpers.format_win_rate(row.win_rate)}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <%!-- By deck name breakdown --%>
        <section :if={@stats.by_deck_name != []}>
          <h2 class="text-lg font-semibold mb-3 font-beleren">By Deck</h2>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Deck</th>
                  <th class="text-right">Matches</th>
                  <th class="text-right">Record</th>
                  <th class="text-right">Win Rate</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @stats.by_deck_name}>
                  <td>{row.key}</td>
                  <td class="text-right tabular-nums">{row.total}</td>
                  <td class="text-right tabular-nums">
                    {StatsHelpers.record(row.wins, row.losses)}
                  </td>
                  <td class={["text-right tabular-nums", StatsHelpers.win_rate_class(row.win_rate)]}>
                    {StatsHelpers.format_win_rate(row.win_rate)}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <%!-- Play vs Draw breakdown --%>
        <section :if={@stats.by_on_play != []}>
          <h2 class="text-lg font-semibold mb-3 font-beleren">Play vs Draw</h2>
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div :for={row <- @stats.by_on_play} class="card bg-base-200">
              <div class="card-body p-4">
                <p class="text-xs uppercase text-base-content/60">
                  {if row.key, do: "On the Play", else: "On the Draw"}
                </p>
                <div class="flex items-baseline gap-3">
                  <span class={["text-2xl font-semibold", StatsHelpers.win_rate_class(row.win_rate)]}>
                    {StatsHelpers.format_win_rate(row.win_rate)}
                  </span>
                  <span class="text-sm text-base-content/60">
                    {StatsHelpers.record(row.wins, row.losses)}
                  </span>
                </div>
              </div>
            </div>
          </div>
        </section>

        <%!-- Mulligan analytics --%>
        <section :if={@mulligan_stats.total_hands > 0}>
          <h2 class="text-lg font-semibold mb-3 font-beleren">Mulligan Analytics</h2>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
            <%!-- Keep rate by hand size --%>
            <div :if={@mulligan_stats.by_hand_size != []}>
              <h3 class="text-sm font-medium text-base-content/60 mb-2">Keep Rate by Hand Size</h3>
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>Cards</th>
                    <th class="text-right">Offered</th>
                    <th class="text-right">Kept</th>
                    <th class="text-right">Keep Rate</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={row <- @mulligan_stats.by_hand_size}>
                    <td class="tabular-nums">{row.hand_size}</td>
                    <td class="text-right tabular-nums">{row.total}</td>
                    <td class="text-right tabular-nums">{row.keeps}</td>
                    <td class="text-right tabular-nums">
                      {StatsHelpers.format_win_rate(row.keep_rate)}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <%!-- Win rate by land count in kept hand --%>
            <div :if={@mulligan_stats.by_land_count != []}>
              <h3 class="text-sm font-medium text-base-content/60 mb-2">
                Win Rate by Lands in Kept Hand
              </h3>
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>Lands</th>
                    <th class="text-right">Games</th>
                    <th class="text-right">Wins</th>
                    <th class="text-right">Win Rate</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={row <- @mulligan_stats.by_land_count}>
                    <td class="tabular-nums">{row.land_count}</td>
                    <td class="text-right tabular-nums">{row.total}</td>
                    <td class="text-right tabular-nums">{row.wins}</td>
                    <td class={[
                      "text-right tabular-nums",
                      StatsHelpers.win_rate_class(row.win_rate)
                    ]}>
                      {StatsHelpers.format_win_rate(row.win_rate)}
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
