defmodule Scry2Web.OpponentComponents do
  @moduledoc """
  Reusable function components for opponent summary panels.

  Provides `<.opponent_panel>`, a self-contained section showing the
  overall record, win rate, optional cumulative win rate chart, and
  match history against a specific opponent.

  ## Usage

      <.opponent_panel
        id="match-opponent"
        opponent={@match.opponent_screen_name}
        history={@opponent_history}
      />

  The `history` list is all previous matches against the opponent (fetched
  by the LiveView via `Matches.opponent_matches/2`). Pass an empty list for
  first-time opponents — the component handles the empty state gracefully.
  """

  use Phoenix.Component

  import Scry2Web.CoreComponents
  import Scry2Web.LiveHelpers

  alias Scry2Web.MatchesHelpers
  alias Scry2Web.OpponentHelpers

  use Scry2Web, :verified_routes

  @doc """
  Renders an opponent history panel: header, stats row, optional chart,
  and a list of prior matches.
  """
  attr :id, :string, required: true
  attr :opponent, :string, required: true
  attr :history, :list, required: true
  attr :winrate_period, :string, default: nil

  def opponent_panel(assigns) do
    {wins, losses} = OpponentHelpers.record(assigns.history)
    period = assigns.winrate_period || winrate_default_period()
    days = winrate_period_to_days(period)

    assigns =
      assign(assigns,
        wins: wins,
        losses: losses,
        win_rate: OpponentHelpers.win_rate(wins, losses),
        latest_rank: OpponentHelpers.latest_rank(assigns.history),
        chart_series: OpponentHelpers.chart_series(assigns.history, days: days),
        winrate_period: period
      )

    ~H"""
    <section class="mb-8">
      <h2 class="text-lg font-semibold mb-4 font-beleren flex items-center gap-2">
        vs {@opponent}
        <.rank_icon :if={@latest_rank} rank={@latest_rank} />
      </h2>

      <p :if={@history == []} class="text-sm text-base-content/50">
        First time playing this opponent.
      </p>

      <div :if={@history != []}>
        <div class="grid grid-cols-2 gap-3 mb-4">
          <.stat_card title="Record" value={record_str(@wins, @losses)} />
          <.stat_card
            title="Win Rate"
            value={format_win_rate(@win_rate)}
            class={win_rate_class(@win_rate)}
          />
        </div>

        <div class="mb-4 space-y-2">
          <div class="flex justify-end">
            <.winrate_period_toggle selected={@winrate_period} />
          </div>
          <div
            id={"#{@id}-chart-#{@winrate_period}"}
            phx-hook="Chart"
            data-chart-type="cumulative_winrate"
            data-series={@chart_series}
            class="min-h-[10rem] rounded-lg bg-base-300/40"
          />
        </div>

        <div class="flex flex-col divide-y divide-base-content/5">
          <.link
            :for={prev <- @history}
            navigate={~p"/matches/#{prev.id}"}
            class="flex items-center gap-4 py-2 hover:bg-base-content/3 rounded px-2 -mx-2 transition-colors"
          >
            <span class={[
              "font-bold w-6 text-center",
              MatchesHelpers.result_letter_class(prev.won)
            ]}>
              {MatchesHelpers.result_letter(prev.won)}
            </span>
            <span class="text-sm text-base-content/60 inline-flex items-center gap-1">
              <.set_icon :if={prev.set_code} code={prev.set_code} />
              {format_label(prev.format)}
            </span>
            <span class="text-xs text-base-content/40 tabular-nums">
              {MatchesHelpers.format_match_datetime(prev.started_at)}
            </span>
          </.link>
        </div>
      </div>
    </section>
    """
  end
end
