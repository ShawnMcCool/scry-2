defmodule Scry2Web.StatsLive do
  @moduledoc """
  LiveView for aggregate match statistics.

  Queries the `Matches` context for win rates, format breakdowns, and
  deck color breakdowns. All data is precomputed in the projection —
  this page only aggregates via SQL GROUP BY.
  """
  use Scry2Web, :live_view

  alias Scry2.Matches
  alias Scry2.Topics
  alias Scry2Web.StatsHelpers

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Topics.subscribe(Topics.matches_updates())

    {:ok, assign(socket, stats: nil, reload_timer: nil)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    stats = Matches.aggregate_stats(player_id: socket.assigns[:active_player_id])
    {:noreply, assign(socket, stats: stats)}
  end

  @impl true
  def handle_info({:match_updated, _}, socket) do
    {:noreply, schedule_reload(socket)}
  end

  def handle_info(:reload_data, socket) do
    stats = Matches.aggregate_stats(player_id: socket.assigns[:active_player_id])
    {:noreply, assign(socket, stats: stats, reload_timer: nil)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app flash={@flash} players={@players} active_player_id={@active_player_id}>
      <h1 class="text-2xl font-semibold mb-6">Stats</h1>

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
          <h2 class="text-lg font-semibold mb-3">By Format</h2>
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
          <h2 class="text-lg font-semibold mb-3">By Deck Colors</h2>
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
          <h2 class="text-lg font-semibold mb-3">By Deck</h2>
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
      </div>
    </Layouts.app>
    """
  end
end
