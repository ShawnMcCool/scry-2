defmodule Scry2Web.PlayerLive do
  @moduledoc """
  LiveView for the player performance profile.

  Dashboard grid layout: hero stats across the top, then a 2-column grid
  with format performance + play/draw on the left, and win rate trend +
  recent form + top decks on the right. Data is scoped to the active
  player selection (or aggregated across all players when nil).
  """
  use Scry2Web, :live_view

  alias Scry2.Decks
  alias Scry2.Matches
  alias Scry2.Topics
  alias Scry2Web.PlayerHelpers

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Topics.subscribe(Topics.matches_updates())

    {:ok, assign(socket, stats: nil, reload_timer: nil)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({:match_updated, _}, socket) do
    {:noreply, schedule_reload(socket)}
  end

  def handle_info(:reload_data, socket) do
    {:noreply, assign(load_data(socket), reload_timer: nil)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp load_data(socket) do
    player_id = socket.assigns[:active_player_id]
    opts = [player_id: player_id]

    stats = Matches.aggregate_stats(opts)
    cumulative_series = Matches.cumulative_win_rate(opts)
    recent = Matches.recent_results(opts)
    streak = Matches.current_streak(opts)
    decks_with_stats = Decks.list_decks_with_stats(player_id)
    top_decks = PlayerHelpers.top_decks(decks_with_stats)

    assign(socket,
      stats: stats,
      cumulative_series: cumulative_series,
      recent: recent,
      streak: streak,
      top_decks: top_decks
    )
  end

  @impl true
  def render(assigns) do
    has_chart = length(assigns.cumulative_series) > 2

    chart_series =
      if has_chart, do: cumulative_winrate_series(assigns.cumulative_series), else: "[]"

    assigns = assign(assigns, has_chart: has_chart, chart_series: chart_series)

    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app
      flash={@flash}
      players={@players}
      active_player_id={@active_player_id}
      current_path={@player_scope_uri}
    >
      <h1 class="text-2xl font-semibold mb-6 font-beleren">Player</h1>

      <.empty_state :if={@stats.total == 0}>
        No completed matches yet. Play some games to see your performance profile.
      </.empty_state>

      <div :if={@stats.total > 0} class="space-y-6">
        <%!-- Hero stats --%>
        <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-5 gap-4">
          <.stat_card title="Matches" value={@stats.total} />
          <.stat_card
            title="Record"
            value={PlayerHelpers.record(@stats.wins, @stats.losses)}
          />
          <.stat_card
            title="Win Rate"
            value={PlayerHelpers.format_win_rate(@stats.win_rate)}
            class={PlayerHelpers.win_rate_class(@stats.win_rate)}
          />
          <.stat_card
            title="Avg Turns"
            value={PlayerHelpers.format_avg(@stats.avg_turns)}
          />
          <.stat_card
            title="Streak"
            value={PlayerHelpers.format_streak(@streak)}
            class={PlayerHelpers.streak_class(@streak)}
          />
        </div>

        <%!-- 2-column grid --%>
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <%!-- Left column: Format Performance + Play vs Draw --%>
          <div class="space-y-6">
            <.format_performance formats={@stats.by_format} />
            <.play_draw by_on_play={@stats.by_on_play} />
          </div>

          <%!-- Right column: Win Rate Trend + Recent Form + Top Decks --%>
          <div class="space-y-6">
            <.win_rate_chart
              has_chart={@has_chart}
              chart_series={@chart_series}
            />
            <.recent_form recent={@recent} />
            <.top_decks decks={@top_decks} />
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ── Components ─────────────────────────────────────────────────────

  attr :formats, :list, required: true

  defp format_performance(assigns) do
    ~H"""
    <section :if={@formats != []}>
      <h2 class="text-base font-semibold mb-3 font-beleren">Format Performance</h2>
      <div class="overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>Format</th>
              <th class="text-right">Record</th>
              <th class="text-right">Win Rate</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @formats}>
              <td>{format_label(row.key)}</td>
              <td class="text-right tabular-nums">
                {PlayerHelpers.record(row.wins, row.losses)}
              </td>
              <td class={["text-right tabular-nums", PlayerHelpers.win_rate_class(row.win_rate)]}>
                {PlayerHelpers.format_win_rate(row.win_rate)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  attr :by_on_play, :list, required: true

  defp play_draw(assigns) do
    ~H"""
    <section :if={@by_on_play != []}>
      <h2 class="text-base font-semibold mb-3 font-beleren">Play vs Draw</h2>
      <div class="grid grid-cols-2 gap-4">
        <div :for={row <- @by_on_play} class="card bg-base-200">
          <div class="card-body p-4 text-center">
            <p class="text-xs uppercase text-base-content/60">
              {if row.key, do: "On the Play", else: "On the Draw"}
            </p>
            <span class={["text-2xl font-semibold", PlayerHelpers.win_rate_class(row.win_rate)]}>
              {PlayerHelpers.format_win_rate(row.win_rate)}
            </span>
            <span class="text-sm text-base-content/60">
              {PlayerHelpers.record(row.wins, row.losses)}
            </span>
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr :has_chart, :boolean, required: true
  attr :chart_series, :string, required: true

  defp win_rate_chart(assigns) do
    ~H"""
    <section>
      <h2 class="text-base font-semibold mb-3 font-beleren">Win Rate Over Time</h2>
      <div
        :if={@has_chart}
        id="player-winrate-chart"
        phx-hook="Chart"
        data-chart-type="cumulative_winrate"
        data-series={@chart_series}
        class="min-h-[12rem] rounded-lg bg-base-300/40"
      />
      <p :if={!@has_chart} class="text-sm text-base-content/50">
        Not enough data for a trend chart yet.
      </p>
    </section>
    """
  end

  attr :recent, :list, required: true

  defp recent_form(assigns) do
    ~H"""
    <section :if={@recent != []}>
      <div class="flex items-center gap-3">
        <span class="text-xs uppercase text-base-content/50">Last {length(@recent)}:</span>
        <div class="flex gap-1">
          <span
            :for={match <- Enum.reverse(@recent)}
            class={[
              "inline-flex items-center justify-center w-6 h-6 rounded text-xs font-bold",
              if(match.won,
                do: "bg-emerald-500/20 text-emerald-400",
                else: "bg-red-500/20 text-red-400"
              )
            ]}
          >
            {if match.won, do: "W", else: "L"}
          </span>
        </div>
        <span class={[
          "text-sm font-semibold",
          recent_form_class(@recent)
        ]}>
          {recent_form_record(@recent)}
        </span>
      </div>
    </section>
    """
  end

  attr :decks, :list, required: true

  defp top_decks(assigns) do
    ~H"""
    <section :if={@decks != []}>
      <h2 class="text-base font-semibold mb-3 font-beleren">Top Decks</h2>
      <div class="flex flex-col gap-2">
        <.link
          :for={deck <- @decks}
          navigate={~p"/decks/#{deck.mtga_deck_id}"}
          class="flex items-center justify-between rounded-lg bg-base-200 px-4 py-3 hover:bg-base-content/5 transition-colors"
        >
          <div class="flex items-center gap-3">
            <span class="font-semibold text-sm">{deck.name}</span>
            <.mana_pips :if={deck.deck_colors} colors={deck.deck_colors} class="text-[0.6rem]" />
            <span class="text-xs text-base-content/40">{deck.total} matches</span>
          </div>
          <div class="flex items-center gap-2">
            <span class={["text-sm font-semibold", PlayerHelpers.win_rate_class(deck.win_rate)]}>
              {PlayerHelpers.format_win_rate(deck.win_rate)}
            </span>
            <span class="text-base-content/30 text-xs">›</span>
          </div>
        </.link>
      </div>
    </section>
    """
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp recent_form_record(recent) do
    wins = Enum.count(recent, & &1.won)
    losses = length(recent) - wins
    "#{wins}–#{losses}"
  end

  defp recent_form_class(recent) do
    wins = Enum.count(recent, & &1.won)
    losses = length(recent) - wins

    cond do
      wins > losses -> "text-emerald-400"
      losses > wins -> "text-red-400"
      true -> "text-base-content"
    end
  end
end
