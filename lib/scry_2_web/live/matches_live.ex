defmodule Scry2Web.MatchesLive do
  @moduledoc """
  LiveView for the matches dashboard, filtered match list, and match detail.

  Index view (`:index`) displays a performance dashboard (stat cards,
  cumulative win rate chart, format breakdown) above a filtered,
  date-grouped, paginated match list. Filters (format, BO1/BO3, W/L)
  are URL params that scope both dashboard stats and the match list.

  Detail view (`:show`) displays a rich match header, game-by-game
  breakdown, submitted deck list, and opponent match history.
  """
  use Scry2Web, :live_view

  alias Scry2.{Cards, Matches}
  alias Scry2.Topics
  alias Scry2Web.MatchesHelpers

  @per_page 20

  # ── Lifecycle ────────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Topics.subscribe(Topics.matches_updates())

    {:ok, assign(socket, reload_timer: nil, show_all_formats: false)}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    match = Matches.get_match_with_associations(String.to_integer(id))

    if match do
      {:noreply, assign_detail(socket, match)}
    else
      {:noreply, push_navigate(socket, to: ~p"/matches")}
    end
  end

  def handle_params(params, _uri, socket) do
    {:noreply, assign_index(socket, params)}
  end

  @impl true
  def handle_event("toggle_all_formats", _params, socket) do
    {:noreply, assign(socket, show_all_formats: !socket.assigns.show_all_formats)}
  end

  @impl true
  def handle_info({:match_updated, _}, socket) do
    {:noreply, schedule_reload(socket)}
  end

  def handle_info(:reload_data, socket) do
    socket = assign(socket, reload_timer: nil)

    if socket.assigns[:match] do
      match = Matches.get_match_with_associations(socket.assigns.match.id)
      {:noreply, assign_detail(socket, match)}
    else
      {:noreply, assign_index(socket, socket.assigns.filter_params)}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # ── Data loading ─────────────────────────────────────────────────────

  defp assign_index(socket, params) do
    player_id = socket.assigns[:active_player_id]
    format = params["format"]
    bo = params["bo"]
    result = params["result"]
    page = parse_page(params["page"])

    filter_opts =
      [player_id: player_id]
      |> maybe_add(:format, format)
      |> maybe_add(:bo, bo)
      |> maybe_add(:won, parse_result(result))

    stats = Matches.aggregate_stats(filter_opts)
    cumulative_series = Matches.cumulative_win_rate(filter_opts)
    format_counts = Matches.format_counts(Keyword.delete(filter_opts, :format))

    matches =
      Matches.list_matches(filter_opts ++ [limit: @per_page, offset: (page - 1) * @per_page])

    total_pages = max(1, ceil(stats.total / @per_page))

    assign(socket,
      match: nil,
      matches: matches,
      stats: stats,
      cumulative_series: cumulative_series,
      format_counts: format_counts,
      page: page,
      total_pages: total_pages,
      filter_params: %{
        "format" => format,
        "bo" => bo,
        "result" => result,
        "page" => to_string(page)
      },
      active_format: format,
      active_bo: bo,
      active_result: result
    )
  end

  defp assign_detail(socket, match) do
    player_id = socket.assigns[:active_player_id]

    opponent_history =
      if match.opponent_screen_name do
        Matches.opponent_matches(match.opponent_screen_name,
          player_id: player_id,
          exclude_match_id: match.id
        )
      else
        []
      end

    deck_submission = List.first(match.deck_submissions || [])

    cards_by_arena_id =
      if deck_submission do
        arena_ids = extract_arena_ids(deck_submission)
        Cards.list_by_arena_ids(arena_ids)
      else
        %{}
      end

    assign(socket,
      match: match,
      matches: [],
      opponent_history: opponent_history,
      deck_submission: deck_submission,
      cards_by_arena_id: cards_by_arena_id
    )
  end

  # ── Index render ─────────────────────────────────────────────────────

  @impl true
  def render(%{match: nil} = assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app
      flash={@flash}
      players={@players}
      active_player_id={@active_player_id}
      current_path={@player_scope_uri}
    >
      <h1 class="text-2xl font-semibold mb-6 font-beleren">Matches</h1>

      <%!-- Dashboard stats --%>
      <.dashboard
        stats={@stats}
        cumulative_series={@cumulative_series}
        show_all_formats={@show_all_formats}
      />

      <%!-- Filter bar --%>
      <.filter_bar
        format_counts={@format_counts}
        active_format={@active_format}
        active_bo={@active_bo}
        active_result={@active_result}
      />

      <%!-- Match list --%>
      <.empty_state :if={@matches == []}>
        No matches found. {if @active_format || @active_bo || @active_result,
          do: "Try adjusting your filters.",
          else: "Play a game with MTGA detailed logs enabled to see entries here."}
      </.empty_state>

      <div :if={@matches != []} class="overflow-x-auto">
        <table class="table w-full">
          <thead>
            <tr class="text-xs text-base-content/60 uppercase">
              <th>Result</th>
              <th>Opponent</th>
              <th>Games</th>
              <th>Event</th>
            </tr>
          </thead>
          <tbody>
            <%= for {date_label, date_matches} <- group_matches_by_date(@matches) do %>
              <tr>
                <td
                  colspan="4"
                  class="text-sm text-base-content/50 font-medium pt-4 pb-1 border-b-0"
                >
                  {date_label}
                </td>
              </tr>
              <.match_table_row :for={match <- date_matches} match={match} />
            <% end %>
          </tbody>
        </table>
      </div>

      <%!-- Pagination --%>
      <.pagination
        :if={@total_pages > 1}
        page={@page}
        total_pages={@total_pages}
        active_format={@active_format}
        active_bo={@active_bo}
        active_result={@active_result}
      />
    </Layouts.app>
    """
  end

  # ── Detail render ────────────────────────────────────────────────────

  def render(%{match: _} = assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app
      flash={@flash}
      players={@players}
      active_player_id={@active_player_id}
      current_path={@player_scope_uri}
    >
      <.back_link navigate={~p"/matches"} label="All matches" />

      <%!-- Rich match header --%>
      <.match_header match={@match} />

      <%!-- Game-by-game breakdown --%>
      <.game_breakdown :if={@match.games != []} games={@match.games} />

      <%!-- Deck list --%>
      <.deck_list
        :if={@deck_submission}
        deck_submission={@deck_submission}
        cards_by_arena_id={@cards_by_arena_id}
      />

      <%!-- Opponent history --%>
      <.opponent_history
        :if={@match.opponent_screen_name}
        opponent={@match.opponent_screen_name}
        history={@opponent_history}
      />
    </Layouts.app>
    """
  end

  # ── Dashboard component ──────────────────────────────────────────────

  defp dashboard(assigns) do
    has_chart = length(assigns.cumulative_series) > 2

    chart_series =
      if has_chart, do: cumulative_winrate_series(assigns.cumulative_series), else: "[]"

    assigns = assign(assigns, has_chart: has_chart, chart_series: chart_series)

    ~H"""
    <div class="mb-6">
      <%!-- Stat cards --%>
      <div class="flex gap-3 mb-4 flex-wrap">
        <.stat_card title="Matches" value={@stats.total} />
        <.stat_card title="Win Rate" value={format_win_rate(@stats.win_rate)} />
        <.stat_card title="Avg Turns" value={if @stats.avg_turns, do: @stats.avg_turns, else: "—"} />
        <.stat_card
          title="Avg Mulligans"
          value={if @stats.avg_mulligans, do: @stats.avg_mulligans, else: "—"}
        />
        <.play_draw_stat by_on_play={@stats.by_on_play} />
      </div>

      <%!-- Chart + format breakdown --%>
      <div class="flex gap-4">
        <div
          :if={@has_chart}
          id="matches-winrate-chart"
          phx-hook="Chart"
          data-chart-type="cumulative_winrate"
          data-series={@chart_series}
          class="flex-[2] min-w-0 min-h-[12rem] rounded-lg bg-base-300/40"
        />
        <.format_breakdown
          :if={@stats.by_format != []}
          formats={@stats.by_format}
          show_all_formats={@show_all_formats}
        />
      </div>
    </div>
    """
  end

  defp play_draw_stat(assigns) do
    play_wr =
      case Enum.find(assigns.by_on_play, fn row -> row.key == true end) do
        nil -> nil
        row -> row.win_rate
      end

    draw_wr =
      case Enum.find(assigns.by_on_play, fn row -> row.key == false end) do
        nil -> nil
        row -> row.win_rate
      end

    assigns = assign(assigns, play_wr: play_wr, draw_wr: draw_wr)

    ~H"""
    <div class="card bg-base-200">
      <div class="card-body p-4 items-center text-center">
        <p class="text-xs uppercase text-base-content/60">Play / Draw</p>
        <p class="text-2xl font-semibold font-beleren tabular-nums">
          <span class={win_rate_class(@play_wr)}>{format_win_rate(@play_wr)}</span>
          <span class="text-base-content/30 mx-0.5">/</span>
          <span class={win_rate_class(@draw_wr)}>{format_win_rate(@draw_wr)}</span>
        </p>
      </div>
    </div>
    """
  end

  attr :formats, :list, required: true
  attr :show_all_formats, :boolean, required: true

  defp format_breakdown(assigns) do
    visible =
      if assigns.show_all_formats, do: assigns.formats, else: Enum.take(assigns.formats, 5)

    has_more = length(assigns.formats) > 5
    overflow_count = length(assigns.formats) - 5

    assigns =
      assigns
      |> assign(:visible_formats, visible)
      |> assign(:has_more, has_more)
      |> assign(:overflow_count, overflow_count)

    ~H"""
    <div class="flex-1 bg-base-200 rounded-box p-4 min-w-[200px]">
      <h3 class="text-xs text-base-content/50 uppercase tracking-wider mb-3">Wins By Format</h3>
      <div class="flex flex-col gap-2">
        <div :for={fmt <- @visible_formats} class="text-sm">
          <div class="flex justify-between mb-1">
            <span class="text-base-content/80 truncate">{format_label(fmt.key)}</span>
            <span class={["tabular-nums", win_rate_class(fmt.win_rate)]}>
              {format_win_rate(fmt.win_rate)} · {record_str(fmt.wins, fmt.losses)}
            </span>
          </div>
          <div class="w-full bg-base-300 rounded-full h-1.5">
            <div
              class={["h-1.5 rounded-full", win_rate_bar_class(fmt.win_rate)]}
              style={"width: #{fmt.win_rate}%"}
            />
          </div>
        </div>
      </div>
      <button
        :if={@has_more}
        phx-click="toggle_all_formats"
        class="text-xs text-base-content/50 hover:text-base-content mt-2 transition-colors"
      >
        {if @show_all_formats, do: "Show less", else: "Show all formats (+#{@overflow_count})"}
      </button>
    </div>
    """
  end

  # ── Filter bar ───────────────────────────────────────────────────────

  defp filter_bar(assigns) do
    ~H"""
    <div class="flex items-center gap-2 flex-wrap py-3 mb-4 border-t border-b border-base-content/5">
      <%!-- Format chips --%>
      <.link
        patch={filter_path(nil, @active_bo, @active_result)}
        class={["btn btn-xs", if(!@active_format, do: "btn-soft btn-primary", else: "btn-ghost")]}
      >
        All Formats
      </.link>
      <.link
        :for={{format, count} <- Enum.sort_by(@format_counts, fn {_, c} -> -c end)}
        patch={filter_path(format, @active_bo, @active_result)}
        class={[
          "btn btn-xs",
          if(@active_format == format, do: "btn-soft btn-primary", else: "btn-ghost")
        ]}
      >
        {format_label(format)}
        <span class="badge badge-xs badge-ghost ml-1">{count}</span>
      </.link>

      <div class="flex-1" />

      <%!-- BO toggle --%>
      <div class="join">
        <.link
          patch={filter_path(@active_format, nil, @active_result)}
          class={["btn btn-xs join-item", if(!@active_bo, do: "btn-active", else: "")]}
        >
          All
        </.link>
        <.link
          patch={filter_path(@active_format, "1", @active_result)}
          class={["btn btn-xs join-item", if(@active_bo == "1", do: "btn-active", else: "")]}
        >
          BO1
        </.link>
        <.link
          patch={filter_path(@active_format, "3", @active_result)}
          class={["btn btn-xs join-item", if(@active_bo == "3", do: "btn-active", else: "")]}
        >
          BO3
        </.link>
      </div>

      <%!-- Result toggle --%>
      <div class="join">
        <.link
          patch={filter_path(@active_format, @active_bo, nil)}
          class={["btn btn-xs join-item", if(!@active_result, do: "btn-active", else: "")]}
        >
          All
        </.link>
        <.link
          patch={filter_path(@active_format, @active_bo, "won")}
          class={["btn btn-xs join-item", if(@active_result == "won", do: "btn-active", else: "")]}
        >
          Wins
        </.link>
        <.link
          patch={filter_path(@active_format, @active_bo, "lost")}
          class={["btn btn-xs join-item", if(@active_result == "lost", do: "btn-active", else: "")]}
        >
          Losses
        </.link>
      </div>
    </div>
    """
  end

  # ── Match list components ────────────────────────────────────────────

  defp match_table_row(assigns) do
    game_results = format_game_results(assigns.match.game_results)
    score = match_score(assigns.match)
    bo3? = assigns.match.num_games && assigns.match.num_games > 1
    assigns = assign(assigns, game_results: game_results, score: score, bo3: bo3?)

    ~H"""
    <tr
      class="hover:bg-base-content/5 cursor-pointer"
      phx-click={JS.navigate(~p"/matches/#{@match.id}")}
    >
      <td class="align-top">
        <span class={
          if @match.won, do: "text-success font-semibold", else: "text-error font-semibold"
        }>
          {if @match.won, do: "Win", else: "Loss"}
        </span>
        <span :if={@score} class="text-sm text-base-content/50 ml-1">{@score}</span>
      </td>
      <td class="align-top">
        <div class="flex items-center gap-1.5">
          <span class="text-sm truncate max-w-[10rem]">
            {@match.opponent_screen_name || "Unknown"}
          </span>
          <.rank_icon
            :if={@match.opponent_rank}
            rank={@match.opponent_rank}
            format_type={@match.format_type || "Limited"}
            class="h-4"
          />
        </div>
      </td>
      <td class="align-top">
        <div :if={@bo3} class="flex flex-col gap-0.5">
          <div :for={game <- @game_results} class="text-sm flex items-center gap-1.5">
            <span class={
              if game.won, do: "text-success font-semibold", else: "text-error font-semibold"
            }>
              {if game.won, do: "W", else: "L"}
            </span>
            <span class={if game.on_play, do: "text-info", else: "text-base-content/70"}>
              {if game.on_play, do: "Play", else: "Draw"}
            </span>
            <span :if={game.num_mulligans > 0} class="text-base-content/40 text-xs">
              · mull ×{game.num_mulligans}
            </span>
          </div>
        </div>
        <div :if={!@bo3} class="text-sm">
          <span class={if @match.on_play, do: "text-info", else: "text-base-content/70"}>
            {MatchesHelpers.on_play_label(@match.on_play)}
          </span>
        </div>
      </td>
      <td class="align-top">
        <div class="flex flex-col gap-0.5 leading-snug">
          <div
            :if={@match.deck_name}
            class="flex items-center gap-1.5 text-sm text-base-content"
          >
            <.link
              :if={@match.mtga_deck_id}
              navigate={~p"/decks/#{@match.mtga_deck_id}"}
              class="hover:text-primary transition-colors"
            >
              {@match.deck_name}
            </.link>
            <span :if={!@match.mtga_deck_id}>{@match.deck_name}</span>
            <.mana_pips
              :if={@match.deck_colors && @match.deck_colors != ""}
              colors={@match.deck_colors}
              class="text-[0.65rem]"
            />
          </div>
          <div
            :if={@match.player_rank}
            class="inline-flex items-center gap-1 text-xs text-base-content/50"
          >
            <.rank_icon
              rank={@match.player_rank}
              format_type={@match.format_type || "Limited"}
              class="h-3.5"
            />
            {@match.player_rank}
          </div>
          <div class="text-xs text-base-content/40 inline-flex items-center gap-1">
            <.set_icon
              :if={@match.set_code}
              code={@match.set_code}
              class="text-sm text-base-content/60"
            />
            {format_label(@match.format)}
          </div>
        </div>
      </td>
    </tr>
    """
  end

  defp pagination(assigns) do
    ~H"""
    <div class="flex items-center justify-center gap-1 mt-6">
      <.link
        :for={p <- 1..@total_pages}
        patch={filter_path(@active_format, @active_bo, @active_result, p)}
        class={["btn btn-xs", if(p == @page, do: "btn-active", else: "btn-ghost")]}
      >
        {p}
      </.link>
    </div>
    """
  end

  # ── Detail view components ───────────────────────────────────────────

  defp match_header(assigns) do
    ~H"""
    <div class="flex items-start gap-5 mb-8 mt-4">
      <div class={[
        "text-5xl font-black tabular-nums shrink-0",
        MatchesHelpers.result_letter_class(@match.won)
      ]}>
        {MatchesHelpers.result_letter(@match.won)}
      </div>

      <div class="flex-1 min-w-0">
        <div class="flex items-baseline gap-3 flex-wrap">
          <h1 class="text-xl font-semibold text-base-content font-beleren">
            vs {@match.opponent_screen_name || "Unknown"}
          </h1>
        </div>

        <div class="flex items-center gap-3 text-sm text-base-content/60 mt-1 flex-wrap">
          <span class="inline-flex items-center gap-1">
            <.set_icon :if={@match.set_code} code={@match.set_code} />
            {format_label(@match.format)}
          </span>
          <span :if={@match.num_games && @match.num_games > 1}>
            Best of 3 · {MatchesHelpers.game_score(@match.game_results, @match.won)}
          </span>
          <span :if={@match.num_games == 1}>Best of 1</span>
        </div>

        <div class="flex items-center gap-4 text-sm text-base-content/45 mt-2 flex-wrap">
          <span :if={@match.started_at} class="tabular-nums">
            {MatchesHelpers.format_match_datetime(@match.started_at)}
          </span>
          <span :if={@match.duration_seconds} class="tabular-nums">
            {format_duration(@match.duration_seconds)}
          </span>
          <span :if={@match.deck_name} class="flex items-center gap-1">
            <.link
              :if={@match.mtga_deck_id}
              navigate={~p"/decks/#{@match.mtga_deck_id}"}
              class="hover:text-primary transition-colors"
            >
              {@match.deck_name}
            </.link>
            <span :if={!@match.mtga_deck_id}>{@match.deck_name}</span>
            <.mana_pips
              :if={@match.deck_colors && @match.deck_colors != ""}
              colors={@match.deck_colors}
              class="text-xs"
            />
          </span>
          <span :if={@match.player_rank}>{@match.player_rank}</span>
          <span :if={@match.on_play != nil}>{MatchesHelpers.on_play_label(@match.on_play)}</span>
        </div>
      </div>
    </div>
    """
  end

  defp game_breakdown(assigns) do
    ~H"""
    <section class="mb-8">
      <h2 class="text-lg font-semibold mb-3 font-beleren">Games</h2>
      <div class="flex gap-3 flex-wrap">
        <div
          :for={game <- Enum.sort_by(@games, & &1.game_number)}
          class="bg-base-200 rounded-box p-4 text-center min-w-[120px] flex-1"
        >
          <div class="text-xs text-base-content/40 uppercase mb-1">Game {game.game_number}</div>
          <div class={["text-2xl font-black mb-1", MatchesHelpers.result_letter_class(game.won)]}>
            {MatchesHelpers.result_letter(game.won)}
          </div>
          <div class="text-xs text-base-content/50 space-y-0.5">
            <div>{MatchesHelpers.on_play_label(game.on_play)}</div>
            <div :if={game.num_turns} class="tabular-nums">{game.num_turns} turns</div>
            <div :if={game.num_mulligans && game.num_mulligans > 0} class="tabular-nums">
              {game.num_mulligans} {if game.num_mulligans == 1, do: "mull", else: "mulls"}
            </div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  defp deck_list(assigns) do
    main_deck = parse_deck_cards(assigns.deck_submission.main_deck, assigns.cards_by_arena_id)
    sideboard = parse_deck_cards(assigns.deck_submission.sideboard, assigns.cards_by_arena_id)
    assigns = assign(assigns, main_deck: main_deck, sideboard: sideboard)

    ~H"""
    <section class="mb-8">
      <h2 class="text-lg font-semibold mb-3 font-beleren">Deck List</h2>
      <div class="bg-base-200 rounded-box p-4">
        <div class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 gap-x-6 gap-y-0.5 text-sm">
          <div :for={{count, name} <- @main_deck} class="flex gap-2">
            <span class="text-base-content/40 tabular-nums w-4 text-right shrink-0">{count}</span>
            <span class="truncate">{name}</span>
          </div>
        </div>
        <div :if={@sideboard != []} class="mt-4 pt-3 border-t border-base-content/10">
          <h3 class="text-xs text-base-content/40 uppercase tracking-wider mb-2">Sideboard</h3>
          <div class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 gap-x-6 gap-y-0.5 text-sm">
            <div :for={{count, name} <- @sideboard} class="flex gap-2">
              <span class="text-base-content/40 tabular-nums w-4 text-right shrink-0">
                {count}
              </span>
              <span class="truncate">{name}</span>
            </div>
          </div>
        </div>
      </div>
    </section>
    """
  end

  defp opponent_history(assigns) do
    wins = Enum.count(assigns.history, & &1.won)
    losses = Enum.count(assigns.history, &(&1.won == false))

    assigns = assign(assigns, wins: wins, losses: losses)

    ~H"""
    <section class="mb-8">
      <h2 class="text-lg font-semibold mb-3 font-beleren">vs {@opponent}</h2>
      <p :if={@history == []} class="text-sm text-base-content/50">
        First time playing this opponent.
      </p>
      <div :if={@history != []}>
        <p class="text-sm text-base-content/60 mb-3">
          Overall record: <span class="font-semibold">{record_str(@wins, @losses)}</span>
        </p>
        <div class="flex flex-col divide-y divide-base-content/5">
          <.link
            :for={prev <- @history}
            navigate={~p"/matches/#{prev.id}"}
            class="flex items-center gap-4 py-2 hover:bg-base-content/3 rounded px-2 -mx-2 transition-colors"
          >
            <span class={["font-bold w-6 text-center", MatchesHelpers.result_letter_class(prev.won)]}>
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

  # ── Private helpers ──────────────────────────────────────────────────

  defp filter_path(format, bo, result, page \\ nil) do
    params =
      %{}
      |> maybe_put("format", format)
      |> maybe_put("bo", bo)
      |> maybe_put("result", result)
      |> maybe_put("page", if(page && page > 1, do: to_string(page)))

    if params == %{}, do: ~p"/matches", else: ~p"/matches?#{params}"
  end

  defp parse_page(nil), do: 1
  defp parse_page(p) when is_binary(p), do: max(1, String.to_integer(p))

  defp parse_result("won"), do: true
  defp parse_result("lost"), do: false
  defp parse_result(_), do: nil

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp extract_arena_ids(deck_submission) do
    main = extract_ids_from_deck_map(deck_submission.main_deck)
    side = extract_ids_from_deck_map(deck_submission.sideboard)
    Enum.uniq(main ++ side)
  end

  defp extract_ids_from_deck_map(nil), do: []

  defp extract_ids_from_deck_map(cards) when is_list(cards) do
    cards
    |> Enum.map(fn card -> card["arena_id"] || card[:arena_id] end)
    |> Enum.filter(&is_integer/1)
  end

  defp extract_ids_from_deck_map(%{"cards" => cards}) when is_list(cards) do
    extract_ids_from_deck_map(cards)
  end

  defp extract_ids_from_deck_map(_), do: []

  defp parse_deck_cards(nil, _cards_by_arena_id), do: []

  defp parse_deck_cards(deck_map, cards_by_arena_id) do
    cards =
      case deck_map do
        %{"cards" => card_list} when is_list(card_list) -> card_list
        cards when is_list(cards) -> cards
        _ -> []
      end

    cards
    |> Enum.map(fn card ->
      arena_id = card["arena_id"] || card[:arena_id]
      count = card["count"] || card[:count] || 1

      name =
        case Map.get(cards_by_arena_id, arena_id) do
          nil -> "#{arena_id}"
          card_data -> card_data.name
        end

      {count, name}
    end)
    |> Enum.sort_by(fn {_count, name} -> name end)
  end
end
