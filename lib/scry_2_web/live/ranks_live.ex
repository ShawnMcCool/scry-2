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

  alias Scry2.Matches
  alias Scry2.Ranks
  alias Scry2.Topics
  alias Scry2Web.RanksHelpers

  @valid_ranges ~w(today week season)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Topics.subscribe(Topics.ranks_updates())

    range_preference =
      case get_connect_params(socket) do
        %{"range_preference" => range} when range in @valid_ranges -> range
        _ -> nil
      end

    {:ok,
     assign(socket,
       seasons: [],
       selected_season: nil,
       range_preference: range_preference,
       time_range: "today",
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
       net_change_constructed: nil,
       net_change_limited: nil,
       chart_x_min: nil,
       chart_x_max: nil,
       chart_y_min_constructed: 0,
       chart_y_max_constructed: 120,
       chart_y_min_limited: 0,
       chart_y_max_limited: 120,
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

    time_range =
      cond do
        params["range"] in @valid_ranges -> params["range"]
        socket.assigns[:range_preference] -> socket.assigns.range_preference
        true -> "today"
      end

    socket =
      socket
      |> assign(seasons: seasons, selected_season: selected_season, time_range: time_range)
      |> load_season_data(player_id, selected_season)

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_season", %{"season" => season_str}, socket) do
    case Integer.parse(season_str) do
      {season, ""} ->
        range = socket.assigns.time_range
        {:noreply, push_patch(socket, to: ~p"/ranks?#{%{season: season, range: range}}")}

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
    <Layouts.app
      flash={@flash}
      players={@players}
      active_player_id={@active_player_id}
      current_path={@player_scope_uri}
    >
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-semibold font-beleren">Rank Progression</h1>
      </div>

      <div :if={@seasons != []} class="flex items-center gap-3 mb-6">
        <.range_toggle selected={@time_range} season={@selected_season} />
        <.season_picker
          seasons={@seasons}
          selected={@selected_season}
          time_range={@time_range}
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
          match_details={@match_details_constructed}
          percentile_series={@percentile_constructed}
          win_rate={@win_rate_constructed}
          peak_score={@peak_score_constructed}
          net_change={@net_change_constructed}
          x_min={@chart_x_min}
          x_max={@chart_x_max}
          y_min={@chart_y_min_constructed}
          y_max={@chart_y_max_constructed}
        />
        <.format_section
          title="Limited"
          format={:limited}
          latest={@latest_snapshot}
          climb_series={@climb_limited}
          results_series={@results_limited}
          match_details={@match_details_limited}
          percentile_series={@percentile_limited}
          win_rate={@win_rate_limited}
          peak_score={@peak_score_limited}
          net_change={@net_change_limited}
          x_min={@chart_x_min}
          x_max={@chart_x_max}
          y_min={@chart_y_min_limited}
          y_max={@chart_y_max_limited}
        />
      </div>
    </Layouts.app>
    """
  end

  # ── Private components ──────────────────────────────────────────────

  attr :seasons, :list, required: true
  attr :selected, :integer, default: nil
  attr :time_range, :string, required: true

  defp season_picker(assigns) do
    prev = prev_season(assigns.seasons, assigns.selected)
    next = next_season(assigns.seasons, assigns.selected)
    assigns = assign(assigns, prev: prev, next: next)

    ~H"""
    <div class="join">
      <.link
        patch={if @prev, do: ~p"/ranks?#{%{season: @prev, range: @time_range}}", else: "#"}
        class={[
          "join-item btn btn-sm px-2",
          if(is_nil(@prev), do: "btn-disabled opacity-30")
        ]}
        aria-label="Previous season"
      >
        ‹
      </.link>

      <form phx-change="select_season" class="join-item">
        <select name="season" class="select select-sm select-bordered rounded-none text-sm h-full">
          <option :for={season <- @seasons} value={season} selected={season == @selected}>
            Season {season}
          </option>
        </select>
      </form>

      <.link
        patch={if @next, do: ~p"/ranks?#{%{season: @next, range: @time_range}}", else: "#"}
        class={[
          "join-item btn btn-sm px-2",
          if(is_nil(@next), do: "btn-disabled opacity-30")
        ]}
        aria-label="Next season"
      >
        ›
      </.link>
    </div>
    """
  end

  attr :selected, :string, required: true
  attr :season, :integer, default: nil

  defp range_toggle(assigns) do
    ~H"""
    <div class="join" id="range-toggle" phx-hook="RangePreference" data-range={@selected}>
      <.link
        :for={{value, label} <- [{"today", "Today"}, {"week", "Past Week"}, {"season", "Season"}]}
        patch={~p"/ranks?#{%{season: @season, range: value}}"}
        class={[
          "join-item btn btn-sm",
          if(@selected == value, do: "btn-primary", else: "btn-ghost")
        ]}
      >
        {label}
      </.link>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :format, :atom, required: true
  attr :latest, :any, default: nil
  attr :climb_series, :string, required: true
  attr :results_series, :string, required: true
  attr :match_details, :string, required: true
  attr :percentile_series, :string, required: true
  attr :win_rate, :float, default: nil
  attr :peak_score, :integer, default: nil
  attr :net_change, :integer, default: nil
  attr :x_min, :string, default: nil
  attr :x_max, :string, default: nil
  attr :y_min, :integer, default: 0
  attr :y_max, :integer, default: 120

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
        net_change={@net_change}
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
            data-results={@results_series}
            data-match-details={@match_details}
            data-x-min={@x_min}
            data-x-max={@x_max}
            data-y-min={@y_min}
            data-y-max={@y_max}
            class="w-full rounded-lg bg-base-200"
            style="height: 15rem"
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
            style="height: 9rem"
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
  attr :net_change, :integer, default: nil
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
            <p
              :if={@net_change && @net_change != 0}
              class={[
                "text-xs tabular-nums",
                if(@net_change > 0, do: "text-success", else: "text-error")
              ]}
            >
              {if(@net_change > 0, do: "+#{@net_change}", else: "#{@net_change}")}
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

    # Chart series use time-filtered snapshots; rank card stats use full season
    chart_snapshots =
      RanksHelpers.filter_snapshots_to_range(snapshots, socket.assigns.time_range)

    {x_min, x_max} = RanksHelpers.chart_time_bounds(chart_snapshots)

    peak_constructed = RanksHelpers.peak_rank_score(chart_snapshots, :constructed)
    min_constructed = RanksHelpers.min_rank_score(chart_snapshots, :constructed)
    peak_limited = RanksHelpers.peak_rank_score(chart_snapshots, :limited)
    min_limited = RanksHelpers.min_rank_score(chart_snapshots, :limited)

    {y_min_c, y_max_c} = RanksHelpers.chart_y_bounds(min_constructed, peak_constructed)
    {y_min_l, y_max_l} = RanksHelpers.chart_y_bounds(min_limited, peak_limited)

    assign(socket,
      snapshots: snapshots,
      latest_snapshot: latest_snapshot,
      chart_x_min: x_min,
      chart_x_max: x_max,
      chart_y_min_constructed: y_min_c,
      chart_y_max_constructed: y_max_c,
      chart_y_min_limited: y_min_l,
      chart_y_max_limited: y_max_l,
      climb_constructed: Jason.encode!(RanksHelpers.climb_series(chart_snapshots, :constructed)),
      climb_limited: Jason.encode!(RanksHelpers.climb_series(chart_snapshots, :limited)),
      results_constructed:
        Jason.encode!(RanksHelpers.match_results_series(chart_snapshots, :constructed)),
      results_limited:
        Jason.encode!(RanksHelpers.match_results_series(chart_snapshots, :limited)),
      match_details_constructed:
        Jason.encode!(match_details_for_chart(chart_snapshots, :constructed)),
      match_details_limited: Jason.encode!(match_details_for_chart(chart_snapshots, :limited)),
      percentile_constructed:
        Jason.encode!(RanksHelpers.percentile_series(chart_snapshots, :constructed)),
      percentile_limited:
        Jason.encode!(RanksHelpers.percentile_series(chart_snapshots, :limited)),
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
      peak_score_limited: RanksHelpers.peak_rank_score(snapshots, :limited),
      net_change_constructed: RanksHelpers.net_rank_change(chart_snapshots, :constructed),
      net_change_limited: RanksHelpers.net_rank_change(chart_snapshots, :limited)
    )
  end

  defp match_details_for_chart([], _format), do: %{}

  defp match_details_for_chart(snapshots, format) do
    first_at = List.first(snapshots).occurred_at
    last_at = List.last(snapshots).occurred_at
    # Pad window to catch matches slightly outside snapshot range
    started_after = DateTime.add(first_at, -300, :second)
    ended_before = DateTime.add(last_at, 300, :second)
    matches = Matches.list_matches_in_range(started_after, ended_before)
    RanksHelpers.match_details_by_timestamp(snapshots, matches, format)
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
