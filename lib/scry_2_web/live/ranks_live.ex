defmodule Scry2Web.RanksLive do
  @moduledoc """
  LiveView for rank progression display.

  Shows the player's current rank state and charts per format:
  - Climb chart: rank position over the season (step line)
  - Match results chart: per-match win/loss bars (+1/-1)
  - Percentile chart: mythic percentile over time (when applicable)

  A season picker (prev/next + select dropdown) lets the user navigate
  across years of data. Subscribes to `ranks:updates` for live updates.
  """
  use Scry2Web, :live_view

  alias Scry2.Ranks
  alias Scry2.Topics
  alias Scry2Web.RanksHelpers

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Topics.subscribe(Topics.ranks_updates())

    {:ok,
     assign(socket,
       seasons: [],
       selected_season: nil,
       snapshots: [],
       latest_snapshot: nil,
       climb_constructed: "[]",
       climb_limited: "[]",
       results_constructed: "[]",
       results_limited: "[]",
       percentile_constructed: "[]",
       percentile_limited: "[]",
       win_rate_constructed: nil,
       win_rate_limited: nil,
       peak_score_constructed: nil,
       peak_score_limited: nil,
       reload_timer: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    player_id = socket.assigns[:active_player_id]
    seasons = Ranks.list_seasons(player_id: player_id)

    selected_season =
      case Integer.parse(params["season"] || "") do
        {ordinal, ""} ->
          if ordinal in seasons, do: ordinal, else: List.first(seasons)

        _ ->
          List.first(seasons)
      end

    socket =
      socket
      |> assign(seasons: seasons, selected_season: selected_season)
      |> load_season_data(player_id, selected_season)

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_season", %{"season" => season_str}, socket) do
    case Integer.parse(season_str) do
      {season, ""} ->
        {:noreply, push_patch(socket, to: ~p"/ranks?season=#{season}")}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:rank_updated, _}, socket) do
    {:noreply, schedule_reload(socket, 2_000)}
  end

  def handle_info(:reload_data, socket) do
    player_id = socket.assigns[:active_player_id]
    seasons = Ranks.list_seasons(player_id: player_id)

    selected_season =
      if socket.assigns.selected_season in seasons,
        do: socket.assigns.selected_season,
        else: List.first(seasons)

    socket =
      socket
      |> assign(seasons: seasons, selected_season: selected_season, reload_timer: nil)
      |> load_season_data(player_id, selected_season)

    {:noreply, socket}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app flash={@flash} players={@players} active_player_id={@active_player_id}>
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-semibold">Rank Progression</h1>
        <.season_picker
          :if={@seasons != []}
          seasons={@seasons}
          selected={@selected_season}
        />
      </div>

      <.empty_state :if={@seasons == []}>
        No rank data yet. Rank snapshots are captured after each ranked match.
      </.empty_state>

      <div :if={@seasons != []} class="space-y-10">
        <.format_section
          title="Constructed"
          format={:constructed}
          latest={@latest_snapshot}
          climb_series={@climb_constructed}
          results_series={@results_constructed}
          percentile_series={@percentile_constructed}
          win_rate={@win_rate_constructed}
          peak_score={@peak_score_constructed}
        />
        <.format_section
          title="Limited"
          format={:limited}
          latest={@latest_snapshot}
          climb_series={@climb_limited}
          results_series={@results_limited}
          percentile_series={@percentile_limited}
          win_rate={@win_rate_limited}
          peak_score={@peak_score_limited}
        />
      </div>
    </Layouts.app>
    """
  end

  # ── Private components ──────────────────────────────────────────────

  attr :seasons, :list, required: true
  attr :selected, :integer, default: nil

  defp season_picker(assigns) do
    prev = prev_season(assigns.seasons, assigns.selected)
    next = next_season(assigns.seasons, assigns.selected)
    assigns = assign(assigns, prev: prev, next: next)

    ~H"""
    <div class="flex items-center gap-2">
      <.link
        patch={if @prev, do: ~p"/ranks?season=#{@prev}", else: "#"}
        class={["btn btn-sm btn-ghost px-2", if(is_nil(@prev), do: "btn-disabled opacity-30")]}
        aria-label="Previous season"
      >
        ‹
      </.link>

      <form phx-change="select_season">
        <select name="season" class="select select-sm select-bordered text-sm">
          <option :for={season <- @seasons} value={season} selected={season == @selected}>
            Season {season}
          </option>
        </select>
      </form>

      <.link
        patch={if @next, do: ~p"/ranks?season=#{@next}", else: "#"}
        class={["btn btn-sm btn-ghost px-2", if(is_nil(@next), do: "btn-disabled opacity-30")]}
        aria-label="Next season"
      >
        ›
      </.link>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :format, :atom, required: true
  attr :latest, :any, default: nil
  attr :climb_series, :string, required: true
  attr :results_series, :string, required: true
  attr :percentile_series, :string, required: true
  attr :win_rate, :float, default: nil
  attr :peak_score, :integer, default: nil

  defp format_section(assigns) do
    {class, level, step, won, lost} =
      case assigns.format do
        :constructed ->
          latest = assigns.latest

          if latest,
            do: {
              latest.constructed_class,
              latest.constructed_level,
              latest.constructed_step,
              latest.constructed_matches_won,
              latest.constructed_matches_lost
            },
            else: {nil, nil, nil, nil, nil}

        :limited ->
          latest = assigns.latest

          if latest,
            do: {
              latest.limited_class,
              latest.limited_level,
              latest.limited_step,
              latest.limited_matches_won,
              latest.limited_matches_lost
            },
            else: {nil, nil, nil, nil, nil}
      end

    peak_label =
      if assigns.peak_score,
        do: RanksHelpers.rank_label_from_score(assigns.peak_score),
        else: nil

    has_percentile = assigns.percentile_series != "[]"

    assigns =
      assign(assigns,
        rank_class: class,
        rank_level: level,
        rank_step: step,
        won: won,
        lost: lost,
        peak_label: peak_label,
        has_percentile: has_percentile
      )

    ~H"""
    <section>
      <h2 class="text-lg font-semibold mb-4 text-base-content/70 uppercase tracking-wider text-sm">
        {@title}
      </h2>

      <.rank_card
        :if={@rank_class}
        rank_class={@rank_class}
        rank_level={@rank_level}
        rank_step={@rank_step}
        won={@won}
        lost={@lost}
        win_rate={@win_rate}
        peak_label={@peak_label}
        format_type={@title}
      />

      <div class="mt-4 space-y-4">
        <div>
          <p class="text-xs text-base-content/40 mb-1 uppercase tracking-wide">Climb</p>
          <div
            id={"chart-climb-#{@format}"}
            phx-hook="Chart"
            data-chart-type="climb"
            data-series={@climb_series}
            class="w-full rounded-lg bg-base-200"
            style="height: 220px"
          />
        </div>
        <div>
          <p class="text-xs text-base-content/40 mb-1 uppercase tracking-wide">Match Results</p>
          <div
            id={"chart-results-#{@format}"}
            phx-hook="Chart"
            data-chart-type="match_results"
            data-series={@results_series}
            class="w-full rounded-lg bg-base-200"
            style="height: 140px"
          />
        </div>
        <div :if={@has_percentile}>
          <p class="text-xs text-base-content/40 mb-1 uppercase tracking-wide">
            Mythic Percentile
          </p>
          <div
            id={"chart-percentile-#{@format}"}
            phx-hook="Chart"
            data-chart-type="percentile"
            data-series={@percentile_series}
            class="w-full rounded-lg bg-base-200"
            style="height: 180px"
          />
        </div>
      </div>
    </section>
    """
  end

  attr :rank_class, :string, required: true
  attr :rank_level, :integer, default: nil
  attr :rank_step, :integer, default: nil
  attr :won, :integer, default: nil
  attr :lost, :integer, default: nil
  attr :win_rate, :float, default: nil
  attr :peak_label, :string, default: nil
  attr :format_type, :string, required: true

  defp rank_card(assigns) do
    {filled, total} = RanksHelpers.step_pips(assigns.rank_step)
    assigns = assign(assigns, filled: filled, total: total)

    ~H"""
    <div class="card bg-base-200">
      <div class="card-body p-5">
        <div class="flex items-center gap-3">
          <.rank_icon rank={@rank_class} format_type={@format_type} class="h-10" />
          <div>
            <p class="text-xl font-semibold">
              {RanksHelpers.format_rank(@rank_class, @rank_level)}
            </p>
            <div class="flex gap-1 mt-1">
              <div
                :for={i <- 1..@total}
                class={[
                  "w-2 h-2 rounded-full",
                  if(i <= @filled, do: "bg-primary", else: "bg-base-content/20")
                ]}
              />
            </div>
          </div>
          <div class="ml-auto text-right space-y-0.5">
            <p class="text-sm text-base-content/60 tabular-nums">
              {RanksHelpers.format_record(@won, @lost)}
            </p>
            <p :if={@win_rate} class="text-xs text-base-content/40 tabular-nums">
              {:erlang.float_to_binary(@win_rate, decimals: 1)}% win rate
            </p>
            <p :if={@peak_label} class="text-xs text-base-content/40">
              Peak: {@peak_label}
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Private helpers ─────────────────────────────────────────────────

  defp load_season_data(socket, _player_id, nil), do: socket

  defp load_season_data(socket, player_id, season) do
    snapshots = Ranks.list_snapshots_for_season(player_id: player_id, season: season)
    latest_snapshot = List.last(snapshots)

    assign(socket,
      snapshots: snapshots,
      latest_snapshot: latest_snapshot,
      climb_constructed: Jason.encode!(RanksHelpers.climb_series(snapshots, :constructed)),
      climb_limited: Jason.encode!(RanksHelpers.climb_series(snapshots, :limited)),
      results_constructed:
        Jason.encode!(RanksHelpers.match_results_series(snapshots, :constructed)),
      results_limited: Jason.encode!(RanksHelpers.match_results_series(snapshots, :limited)),
      percentile_constructed:
        Jason.encode!(RanksHelpers.percentile_series(snapshots, :constructed)),
      percentile_limited: Jason.encode!(RanksHelpers.percentile_series(snapshots, :limited)),
      win_rate_constructed:
        RanksHelpers.win_rate(
          latest_snapshot && latest_snapshot.constructed_matches_won,
          latest_snapshot && latest_snapshot.constructed_matches_lost
        ),
      win_rate_limited:
        RanksHelpers.win_rate(
          latest_snapshot && latest_snapshot.limited_matches_won,
          latest_snapshot && latest_snapshot.limited_matches_lost
        ),
      peak_score_constructed: RanksHelpers.peak_rank_score(snapshots, :constructed),
      peak_score_limited: RanksHelpers.peak_rank_score(snapshots, :limited)
    )
  end

  defp prev_season(seasons, current) do
    index = Enum.find_index(seasons, &(&1 == current))
    if index && index < length(seasons) - 1, do: Enum.at(seasons, index + 1), else: nil
  end

  defp next_season(seasons, current) do
    index = Enum.find_index(seasons, &(&1 == current))
    if index && index > 0, do: Enum.at(seasons, index - 1), else: nil
  end
end
