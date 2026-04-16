defmodule Scry2Web.DecksLive do
  @moduledoc """
  LiveView for the decks list and deck detail pages.

  List view (`:index`) shows all constructed decks that have been played,
  with BO1 and BO3 win/loss records. Detail view (`:show`) has three tabs:

  - **Overview** — performance stats at top, composition (mana curve, card
    list, card image stacks) below, current sideboard as a horizontal splay
    at the bottom.
  - **Matches** — chronological match history for this deck.
  - **Changes** — timeline of DeckUpdated domain events showing how the deck
    has evolved over time.
  """
  use Scry2Web, :live_view

  alias Scry2.Cards
  alias Scry2.Cards.ImageCache
  alias Scry2.Decks
  alias Scry2.Topics
  alias Scry2Web.DecksAnalysisHelpers
  alias Scry2Web.DecksHelpers

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Topics.subscribe(Topics.decks_updates())

    {:ok,
     assign(socket,
       decks: [],
       deck: nil,
       deck_filter: :played,
       performance: nil,
       versions: [],
       version_matches: %{},
       matches: [],
       matches_total: 0,
       matches_page: 1,
       matches_total_pages: 1,
       format_counts: %{bo1: 0, bo3: 0},
       active_format: nil,
       cards_by_arena_id: %{},
       active_tab: :overview,
       mulligan_analytics: nil,
       mulligan_heatmap: [],
       card_performance: [],
       card_sort: :type,
       reload_timer: nil
     )}
  end

  @impl true
  def handle_params(%{"deck_id" => deck_id} = params, _uri, socket) do
    deck = Decks.get_deck(deck_id)

    if is_nil(deck) do
      {:noreply, push_navigate(socket, to: ~p"/decks")}
    else
      tab = parse_tab(params["tab"])
      format = parse_format(params["format"])
      page = parse_page(params["page"])
      socket = load_deck_detail(socket, deck, tab, format, page)
      {:noreply, socket}
    end
  end

  def handle_params(params, _uri, socket) do
    player_id = socket.assigns[:active_player_id]
    deck_filter = parse_deck_filter(params["filter"])
    decks = Decks.list_decks_with_stats(player_id, only_played: deck_filter == :played)
    {:noreply, assign(socket, decks: decks, deck: nil, deck_filter: deck_filter)}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    deck = socket.assigns.deck
    {:noreply, push_patch(socket, to: ~p"/decks/#{deck.mtga_deck_id}?tab=#{tab}")}
  end

  def handle_event("sort_cards", %{"by" => sort_key}, socket) do
    {:noreply, assign(socket, card_sort: String.to_existing_atom(sort_key))}
  end

  @impl true
  def handle_info({:deck_updated, _}, socket) do
    {:noreply, schedule_reload(socket)}
  end

  def handle_info(:reload_data, socket) do
    player_id = socket.assigns[:active_player_id]

    socket =
      case socket.assigns.deck do
        nil ->
          deck_filter = socket.assigns.deck_filter
          decks = Decks.list_decks_with_stats(player_id, only_played: deck_filter == :played)
          assign(socket, decks: decks, reload_timer: nil)

        deck ->
          fresh_deck = Decks.get_deck(deck.mtga_deck_id)

          socket
          |> load_deck_detail(
            fresh_deck,
            socket.assigns.active_tab,
            socket.assigns.active_format,
            socket.assigns.matches_page
          )
          |> assign(reload_timer: nil)
      end

    {:noreply, socket}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(%{deck: nil} = assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app
      flash={@flash}
      players={@players}
      active_player_id={@active_player_id}
      current_path={@player_scope_uri}
    >
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-2xl font-semibold font-beleren">Decks</h1>
        <div class="flex items-center gap-1">
          <.link
            patch={~p"/decks?filter=played"}
            class={["btn btn-sm", if(@deck_filter == :played, do: "btn-primary", else: "btn-ghost")]}
          >
            Played Decks
          </.link>
          <.link
            patch={~p"/decks?filter=all"}
            class={["btn btn-sm", if(@deck_filter == :all, do: "btn-primary", else: "btn-ghost")]}
          >
            All Decks
          </.link>
        </div>
      </div>

      <.empty_state :if={@decks == [] and @deck_filter == :played}>
        No constructed decks recorded yet. Play a match to start tracking deck performance.
      </.empty_state>

      <.empty_state :if={@decks == [] and @deck_filter == :all}>
        No decks found. Decks appear here after MTGA emits a DeckUpdated event.
      </.empty_state>

      <div :if={@decks != []} class="overflow-x-auto">
        <table class="table table-zebra w-full">
          <thead>
            <tr class="text-xs text-base-content/60 uppercase">
              <th>Deck</th>
              <th>Format</th>
              <th class="text-center">BO1</th>
              <th class="text-center">BO3</th>
              <th class="text-right">Last Played</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={entry <- @decks}
              class="cursor-pointer hover:bg-base-content/5 transition-colors"
              phx-click={JS.navigate(~p"/decks/#{entry.deck.mtga_deck_id}")}
            >
              <td>
                <div class="flex items-center gap-2">
                  <span class="font-medium">{entry.deck.current_name || "Unnamed Deck"}</span>
                  <span :if={entry.deck.format} class="flex gap-0.5">
                    <.mana_pips
                      :if={entry.deck.current_main_deck}
                      colors={DecksHelpers.deck_colors(entry.deck)}
                      class="text-[0.65rem]"
                    />
                  </span>
                </div>
              </td>
              <td class="text-sm text-base-content/70">{entry.deck.format}</td>
              <td class="text-center">
                <.record_cell stats={entry.bo1} />
              </td>
              <td class="text-center">
                <.record_cell stats={entry.bo3} />
              </td>
              <td class="text-right text-sm text-base-content/60">
                {DecksHelpers.relative_time(entry.deck.last_played_at)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app
      flash={@flash}
      players={@players}
      active_player_id={@active_player_id}
      current_path={@player_scope_uri}
    >
      <%!-- Deck header --%>
      <div class="flex items-start justify-between mb-6">
        <div>
          <div class="flex items-center gap-2 mb-1">
            <.link
              navigate={~p"/decks"}
              class="text-sm text-base-content/50 hover:text-base-content transition-colors"
            >
              Decks
            </.link>
            <span class="text-base-content/30">/</span>
            <span class="text-sm text-base-content/70">{@deck.current_name || "Unnamed Deck"}</span>
          </div>
          <h1 class="text-2xl font-semibold font-beleren">{@deck.current_name || "Unnamed Deck"}</h1>
          <div class="flex items-center gap-3 mt-1 text-sm text-base-content/60">
            <.mana_pips
              :if={DecksHelpers.deck_colors(@deck) != ""}
              colors={DecksHelpers.deck_colors(@deck)}
              class="text-[0.65rem]"
            />
          </div>
        </div>
      </div>

      <%!-- Tabs --%>
      <div role="tablist" class="tabs tabs-border mb-6">
        <.tab_link label="Overview" tab={:overview} active={@active_tab} deck={@deck} />
        <.tab_link label="Analysis" tab={:analysis} active={@active_tab} deck={@deck} />
        <.tab_link
          label="Matches"
          tab={:matches}
          active={@active_tab}
          deck={@deck}
          count={@match_count}
        />
        <.tab_link
          label="Versions"
          tab={:changes}
          active={@active_tab}
          deck={@deck}
          count={if(@version_count > 1, do: @version_count)}
        />
      </div>

      <%!-- Tab content --%>
      <%= case @active_tab do %>
        <% :overview -> %>
          <.overview_tab
            performance={@performance}
            deck={@deck}
            cards_by_arena_id={@cards_by_arena_id}
          />
        <% :matches -> %>
          <.matches_tab
            matches={@matches}
            matches_total={@matches_total}
            matches_page={@matches_page}
            matches_total_pages={@matches_total_pages}
            format_counts={@format_counts}
            active_format={@active_format}
            deck={@deck}
          />
        <% :changes -> %>
          <.changes_tab
            versions={@versions}
            version_matches={@version_matches}
            cards_by_arena_id={@cards_by_arena_id}
          />
        <% :analysis -> %>
          <.analysis_tab
            mulligan_analytics={@mulligan_analytics}
            mulligan_heatmap={@mulligan_heatmap}
            card_performance={@card_performance}
            cards_by_arena_id={@cards_by_arena_id}
            card_sort={@card_sort}
            deck={@deck}
          />
      <% end %>
    </Layouts.app>
    """
  end

  # ── Private components ───────────────────────────────────────────────

  attr :stats, :map, required: true

  defp record_cell(%{stats: %{total: 0}} = assigns) do
    ~H"""
    <span class="text-base-content/30 text-sm">—</span>
    """
  end

  defp record_cell(assigns) do
    ~H"""
    <div class="text-sm">
      <span class={DecksHelpers.win_rate_class(@stats.win_rate)}>
        {DecksHelpers.format_win_rate(@stats.win_rate)}
      </span>
      <span class="text-base-content/50 ml-1">{@stats.wins}W–{@stats.losses}L</span>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :tab, :atom, required: true
  attr :active, :atom, required: true
  attr :deck, :map, required: true
  attr :count, :integer, default: nil

  defp tab_link(assigns) do
    ~H"""
    <a
      role="tab"
      class={["tab", @active == @tab && "tab-active"]}
      phx-click="switch_tab"
      phx-value-tab={@tab}
    >
      {@label}
      <span :if={@count && @count > 0} class="badge badge-sm badge-ghost ml-1.5">
        {@count}
      </span>
    </a>
    """
  end

  attr :performance, :map, required: true
  attr :deck, :map, required: true
  attr :cards_by_arena_id, :map, required: true

  defp overview_tab(assigns) do
    cmc_columns = DecksHelpers.group_cards_by_cmc(assigns.deck, assigns.cards_by_arena_id)

    card_list_columns =
      DecksHelpers.card_list_with_sideboard(assigns.deck, assigns.cards_by_arena_id)

    sideboard = DecksHelpers.sideboard_cards(assigns.deck, assigns.cards_by_arena_id)
    main_deck_total = Enum.sum(for {_, cards} <- cmc_columns, card <- cards, do: card.count)

    assigns =
      assign(assigns,
        cmc_columns: cmc_columns,
        card_list_columns: card_list_columns,
        sideboard: sideboard,
        main_deck_total: main_deck_total
      )

    ~H"""
    <div class="space-y-8">
      <%!-- Performance --%>
      <.performance_section performance={@performance} />

      <div :if={@card_list_columns != []}>
        <%!-- Mana Curve — half width, space reserved for future chart --%>
        <div class="w-1/2">
          <div
            id="deck-curve-chart"
            phx-hook="Chart"
            data-chart-type="curve"
            data-series={DecksHelpers.mana_curve_series(@deck, @cards_by_arena_id)}
            class="w-full rounded-lg bg-base-200"
            style="height: 5rem"
          />
        </div>

        <%!-- Card List — columns by type + sideboard --%>
        <div class="flex gap-8 mt-8">
          <div :for={{type_label, cards} <- @card_list_columns}>
            <h3 class="flex items-center gap-2 text-xs font-medium text-base-content/40 uppercase tracking-wide mb-1">
              <span class="w-4 shrink-0" />{type_label} ({Enum.sum(Enum.map(cards, & &1.count))})
            </h3>
            <div class="space-y-0.5">
              <div
                :for={card <- cards}
                id={"card-row-#{card.arena_id}"}
                class="flex items-baseline gap-2 text-sm py-0.5 cursor-default"
                phx-hook={if ImageCache.cached?(card.arena_id), do: "CardHover"}
                data-card-src={ImageCache.url_for(card.arena_id)}
                data-card-alt={card.name}
              >
                <span class="text-base-content/50 w-4 text-right tabular-nums shrink-0">
                  {card.count}
                </span>
                <span>{card.name}</span>
              </div>
            </div>
          </div>
        </div>

        <%!-- Deck View header --%>
        <h3 class="text-xs font-medium text-base-content/40 uppercase tracking-wide mt-8">
          Main Deck ({@main_deck_total})
        </h3>

        <%!-- Compact deck grid — responsive, no wrapping --%>
        <div id="deck-view-compact" phx-hook="DeckView" class="mt-3">
          <div class="flex gap-3 items-start" data-deck-grid>
            <div
              :for={{cmc_label, cards} <- @cmc_columns}
              class="flex-1 min-w-0 flex flex-col items-center"
            >
              <p class="text-xs text-base-content/30 mb-1">{cmc_label}</p>
              <div
                class="relative w-full"
                style={"aspect-ratio: #{DecksHelpers.card_stack_aspect_ratio(length(cards))}"}
              >
                <div
                  :for={{card, index} <- Enum.with_index(cards)}
                  class="absolute w-full left-0"
                  style={"top: #{DecksHelpers.card_top_percent(index, length(cards))}%; z-index: #{index}"}
                >
                  <.card_image
                    id={"card-grid-#{card.arena_id}"}
                    arena_id={card.arena_id}
                    name={card.name}
                    class="w-full"
                  />
                  <span class="absolute top-1 right-1 min-w-5 text-center rounded bg-black/70 px-1 text-xs font-bold text-white pointer-events-none">
                    {card.count}
                  </span>
                </div>
              </div>
            </div>
          </div>

          <.sideboard_splay :if={@sideboard != []} cards={@sideboard} />
        </div>
      </div>

      <.empty_state :if={@card_list_columns == []}>
        No composition data available. A DeckUpdated event is needed to show the current list.
      </.empty_state>
    </div>
    """
  end

  attr :performance, :map, required: true

  defp performance_section(%{performance: nil} = assigns) do
    ~H"""
    <.empty_state>No match data yet.</.empty_state>
    """
  end

  defp performance_section(assigns) do
    ~H"""
    <div class="grid grid-cols-1 md:grid-cols-2 gap-4 items-stretch">
      <.stats_panel
        title="Best-of-1"
        stats={@performance.bo1}
        format={:bo1}
        cumulative_series={@performance.cumulative_win_rate.bo1}
      />
      <.stats_panel
        title="Best-of-3"
        stats={@performance.bo3}
        format={:bo3}
        cumulative_series={@performance.cumulative_win_rate.bo3}
      />
    </div>
    """
  end

  attr :cards, :list, required: true
  attr :mode, :atom, default: :compact

  defp sideboard_splay(assigns) do
    total = Enum.sum(Enum.map(assigns.cards, & &1.count))
    assigns = assign(assigns, total: total)

    ~H"""
    <div id="sideboard-splay" class="mt-8" data-sideboard-splay>
      <h3 class="text-xs font-medium text-base-content/40 uppercase tracking-wide mb-3">
        Sideboard ({@total})
      </h3>
      <div data-splay-container class="flex items-end pb-4">
        <div :for={card <- @cards} class="relative flex-shrink-0" data-splay-card>
          <.card_image
            id={"sideboard-#{card.arena_id}"}
            arena_id={card.arena_id}
            name={card.name}
            class={if @mode == :compact, do: "w-full", else: "w-28"}
          />
          <span class="absolute bottom-1 left-1 min-w-5 text-center rounded bg-black/70 px-1 text-xs font-bold text-white pointer-events-none">
            {card.count}
          </span>
        </div>
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :stats, :map, required: true
  attr :format, :atom, required: true
  attr :cumulative_series, :list, default: []

  defp stats_panel(assigns) do
    chart_series = DecksHelpers.cumulative_winrate_series(assigns.cumulative_series)
    has_trend = length(assigns.cumulative_series) > 2

    assigns =
      assigns
      |> assign(:chart_series, chart_series)
      |> assign(:has_trend, has_trend)

    ~H"""
    <div class="bg-base-200 rounded-xl p-5 flex gap-4 h-full">
      <div class="flex flex-col gap-3 w-52 shrink-0">
        <h3 class="text-xs font-semibold text-base-content/40 uppercase tracking-widest">
          {@title}
        </h3>
        <.stats_body stats={@stats} format={@format} />
      </div>
      <div
        :if={@has_trend}
        id={"deck-winrate-#{@format}"}
        phx-hook="Chart"
        data-chart-type="cumulative_winrate"
        data-series={@chart_series}
        class="flex-1 min-w-0 min-h-[12rem] rounded-lg bg-base-300/40"
      />
      <div
        :if={!@has_trend}
        class="flex-1 min-w-0 min-h-[12rem] rounded-lg bg-base-300/40 flex items-center justify-center"
      >
        <span class="text-sm text-base-content/20">Not enough data for trend</span>
      </div>
    </div>
    """
  end

  attr :stats, :map, required: true
  attr :format, :atom, required: true

  defp stats_body(%{stats: %{total: 0}} = assigns) do
    ~H"""
    <div class="flex-1 flex flex-col justify-center gap-1">
      <span class="text-3xl font-black tabular-nums text-base-content/20">—</span>
      <span class="text-base-content/30 text-sm">No matches yet</span>
    </div>
    """
  end

  defp stats_body(assigns) do
    ~H"""
    <div class="flex flex-col gap-2">
      <div class="flex flex-col gap-0.5">
        <span class={[
          "text-3xl font-black tabular-nums",
          DecksHelpers.win_rate_class(@stats.win_rate)
        ]}>
          {DecksHelpers.format_win_rate(@stats.win_rate)}
        </span>
        <span class="text-base-content/50 text-sm">{@stats.wins}W – {@stats.losses}L</span>
      </div>
      <div class="border-t border-base-300" />
      <div class="grid grid-cols-2 gap-x-3 gap-y-2 text-sm">
        <.stat_row
          label="On Play"
          win_rate={@stats.on_play_win_rate}
          total={@stats.on_play_total}
          wins={@stats.on_play_wins}
        />
        <.stat_row
          label="On Draw"
          win_rate={@stats.on_draw_win_rate}
          total={@stats.on_draw_total}
          wins={@stats.on_draw_wins}
        />
        <.stat_row
          :if={@format == :bo3}
          label="Game 1"
          win_rate={@stats[:game1_win_rate]}
          total={@stats[:game1_total] || 0}
          wins={@stats[:game1_wins] || 0}
        />
        <.stat_row
          :if={@format == :bo3}
          label="Games 2–3"
          win_rate={@stats[:games_2_3_win_rate]}
          total={@stats[:games_2_3_total] || 0}
          wins={@stats[:games_2_3_wins] || 0}
        />
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :win_rate, :float, default: nil
  attr :total, :integer, required: true
  attr :wins, :integer, required: true

  defp stat_row(assigns) do
    losses = assigns.total - assigns.wins
    record = if assigns.total > 0, do: DecksHelpers.record_str(assigns.wins, losses), else: nil
    assigns = assign(assigns, :record, record)

    ~H"""
    <div>
      <div class="text-base-content/50 text-xs">{@label}</div>
      <div class={["font-medium", DecksHelpers.win_rate_class(@win_rate)]}>
        {DecksHelpers.format_win_rate(@win_rate)}
        <span :if={@record} class="text-xs text-base-content/50">{@record}</span>
      </div>
    </div>
    """
  end

  attr :matches, :list, required: true
  attr :matches_total, :integer, required: true
  attr :matches_page, :integer, required: true
  attr :matches_total_pages, :integer, required: true
  attr :format_counts, :map, required: true
  attr :active_format, :atom, required: true
  attr :deck, :map, required: true

  defp matches_tab(assigns) do
    grouped = DecksHelpers.group_matches_by_date(assigns.matches)
    assigns = assign(assigns, :grouped_matches, grouped)

    ~H"""
    <%!-- Format switcher --%>
    <div class="flex items-center gap-2 mb-4">
      <div class="inline-flex bg-base-300 rounded-lg p-0.5 gap-0.5">
        <.format_switch_btn
          label="BO3"
          format={:bo3}
          active={@active_format}
          count={@format_counts.bo3}
          deck={@deck}
        />
        <.format_switch_btn
          label="BO1"
          format={:bo1}
          active={@active_format}
          count={@format_counts.bo1}
          deck={@deck}
        />
      </div>
    </div>

    <%!-- Empty state --%>
    <.empty_state :if={@matches == []}>
      No {bo_label(@active_format)} matches recorded for this deck yet.
    </.empty_state>

    <%!-- Match table --%>
    <div :if={@matches != []} class="overflow-x-auto">
      <table class="table w-full">
        <thead>
          <tr class="text-xs text-base-content/60 uppercase">
            <th>Result</th>
            <th>Opponent</th>
            <th>{if @active_format == :bo3, do: "Games", else: "Play / Draw"}</th>
            <th>Event</th>
          </tr>
        </thead>
        <tbody>
          <%= for {date_label, date_matches} <- @grouped_matches do %>
            <tr>
              <td
                colspan="4"
                class="text-sm text-base-content/50 font-medium pt-4 pb-1 border-b-0"
              >
                {date_label}
              </td>
            </tr>
            <.match_row
              :for={match <- date_matches}
              match={match}
              format={@active_format}
              deck={@deck}
            />
          <% end %>
        </tbody>
      </table>

      <%!-- Pagination --%>
      <.matches_pagination
        :if={@matches_total_pages > 1}
        page={@matches_page}
        total_pages={@matches_total_pages}
        total={@matches_total}
        format={@active_format}
        deck={@deck}
      />
    </div>
    """
  end

  defp bo_label(:bo1), do: "BO1"
  defp bo_label(:bo3), do: "BO3"
  defp bo_label(_), do: ""

  attr :label, :string, required: true
  attr :format, :atom, required: true
  attr :active, :atom, required: true
  attr :count, :integer, required: true
  attr :deck, :map, required: true

  defp format_switch_btn(%{count: 0, format: format, active: active} = assigns)
       when format != active do
    ~H"""
    <span class="px-4 py-1.5 rounded-md text-sm font-medium text-base-content/30 cursor-not-allowed">
      {@label}
    </span>
    """
  end

  defp format_switch_btn(assigns) do
    ~H"""
    <.link
      patch={~p"/decks/#{@deck.mtga_deck_id}?tab=matches&format=#{@format}"}
      class={[
        "px-4 py-1.5 rounded-md text-sm font-medium transition-colors",
        if(@active == @format,
          do: "bg-base-100 text-base-content shadow-sm",
          else: "text-base-content/60 hover:text-base-content"
        )
      ]}
    >
      {@label}
    </.link>
    """
  end

  attr :match, :map, required: true
  attr :format, :atom, required: true
  attr :deck, :map, required: true

  defp match_row(%{format: :bo3} = assigns) do
    game_results = DecksHelpers.format_game_results(assigns.match.game_results)
    score = DecksHelpers.match_score(assigns.match)
    assigns = assign(assigns, game_results: game_results, score: score)

    ~H"""
    <tr class="hover:bg-base-content/5">
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
            format_type={@match.format_type || "Constructed"}
            class="h-4"
          />
        </div>
      </td>
      <td class="align-top">
        <div class="flex flex-col gap-0.5">
          <div :for={game <- @game_results} class="text-sm flex items-center gap-1.5">
            <span class={
              if game.won, do: "text-success font-semibold", else: "text-error font-semibold"
            }>
              {if game.won, do: "W", else: "L"}
            </span>
            <span class={if game.on_play, do: "text-info", else: "text-base-content/70"}>
              {if game.on_play, do: "play", else: "draw"}
            </span>
            <span :if={game.num_mulligans > 0} class="text-base-content/40 text-xs">
              · mull ×{game.num_mulligans}
            </span>
          </div>
        </div>
      </td>
      <td class="align-top">
        <div class="text-sm text-base-content/70">
          {DecksHelpers.humanize_event(@match.event_name, @deck.format)}
        </div>
        <div
          :if={@match.player_rank}
          class="inline-flex items-center gap-1 text-xs text-base-content/50 mt-0.5"
        >
          <.rank_icon
            rank={@match.player_rank}
            format_type={@match.format_type || "Constructed"}
            class="h-3.5"
          />
          {@match.player_rank}
        </div>
      </td>
    </tr>
    """
  end

  defp match_row(%{format: :bo1} = assigns) do
    game_results = DecksHelpers.format_game_results(assigns.match.game_results)
    game = List.first(game_results)
    assigns = assign(assigns, :game, game)

    ~H"""
    <tr class="hover:bg-base-content/5">
      <td>
        <span class={
          if @match.won, do: "text-success font-semibold", else: "text-error font-semibold"
        }>
          {if @match.won, do: "Win", else: "Loss"}
        </span>
      </td>
      <td>
        <div class="flex items-center gap-1.5">
          <span class="text-sm truncate max-w-[10rem]">
            {@match.opponent_screen_name || "Unknown"}
          </span>
          <.rank_icon
            :if={@match.opponent_rank}
            rank={@match.opponent_rank}
            format_type={@match.format_type || "Constructed"}
            class="h-4"
          />
        </div>
      </td>
      <td class="text-sm">
        <%= if @game do %>
          <span class={if @game.on_play, do: "text-info", else: "text-base-content/70"}>
            {if @game.on_play, do: "play", else: "draw"}
          </span>
          <span :if={@game.num_mulligans > 0} class="text-base-content/40 text-xs">
            · mull ×{@game.num_mulligans}
          </span>
        <% else %>
          <span class={if @match.on_play, do: "text-info", else: "text-base-content/70"}>
            {case @match.on_play do
              true -> "play"
              false -> "draw"
              nil -> "—"
            end}
          </span>
        <% end %>
      </td>
      <td>
        <div class="text-sm text-base-content/70">
          {DecksHelpers.humanize_event(@match.event_name, @deck.format)}
        </div>
        <div
          :if={@match.player_rank}
          class="inline-flex items-center gap-1 text-xs text-base-content/50 mt-0.5"
        >
          <.rank_icon
            rank={@match.player_rank}
            format_type={@match.format_type || "Constructed"}
            class="h-3.5"
          />
          {@match.player_rank}
        </div>
      </td>
    </tr>
    """
  end

  defp match_row(assigns) do
    ~H"""
    <tr class="hover:bg-base-content/5">
      <td>
        <span class={
          if @match.won, do: "text-success font-semibold", else: "text-error font-semibold"
        }>
          {if @match.won, do: "Win", else: "Loss"}
        </span>
      </td>
      <td class="text-sm text-base-content/70">—</td>
      <td class="text-sm text-base-content/70">
        {DecksHelpers.humanize_event(@match.event_name, @deck.format)}
      </td>
    </tr>
    """
  end

  attr :page, :integer, required: true
  attr :total_pages, :integer, required: true
  attr :total, :integer, required: true
  attr :format, :atom, required: true
  attr :deck, :map, required: true

  defp matches_pagination(assigns) do
    start_item = (assigns.page - 1) * 20 + 1
    end_item = min(assigns.page * 20, assigns.total)
    assigns = assign(assigns, start_item: start_item, end_item: end_item)

    ~H"""
    <div class="flex items-center justify-between px-2 py-3 text-sm">
      <span class="text-base-content/50 text-xs">
        Showing {@start_item}–{@end_item} of {@total} matches
      </span>
      <div class="flex gap-1">
        <.link
          :for={p <- 1..@total_pages}
          patch={~p"/decks/#{@deck.mtga_deck_id}?tab=matches&format=#{@format}&page=#{p}"}
          class={[
            "px-2.5 py-1 rounded text-xs border",
            if(p == @page,
              do: "bg-base-300 text-base-content border-base-content/20",
              else: "border-base-300 text-base-content/50 hover:border-base-content/30"
            )
          ]}
        >
          {p}
        </.link>
      </div>
    </div>
    """
  end

  # ── Analysis tab ──────────────────────────────────────────────────────

  alias Scry2Web.DecksAnalysisHelpers, as: AH

  attr :mulligan_analytics, :map
  attr :mulligan_heatmap, :list, required: true
  attr :card_performance, :list, required: true
  attr :cards_by_arena_id, :map, required: true
  attr :card_sort, :atom, default: :type
  attr :deck, :map, required: true

  defp analysis_tab(%{mulligan_analytics: nil} = assigns) do
    ~H"""
    <.empty_state>Not enough data for analysis yet. Play some games with this deck!</.empty_state>
    """
  end

  defp analysis_tab(%{mulligan_analytics: %{total_hands: 0}} = assigns) do
    ~H"""
    <.empty_state>No mulligan data recorded for this deck yet.</.empty_state>
    """
  end

  defp analysis_tab(assigns) do
    ~H"""
    <%!-- Mulligan Analytics Section --%>
    <section class="mb-10">
      <h3 class="text-lg font-semibold mb-4">Mulligan Analytics</h3>

      <%!-- Headline stat cards --%>
      <div class="grid grid-cols-3 gap-4 mb-6">
        <div class="bg-base-200 rounded-lg p-4 text-center">
          <div class="text-2xl font-bold">{@mulligan_analytics.total_hands}</div>
          <div class="text-xs text-base-content/60">Hands Seen</div>
        </div>
        <div class="bg-base-200 rounded-lg p-4 text-center">
          <div class={"text-2xl font-bold #{DecksHelpers.win_rate_class(@mulligan_analytics.keep_rate)}"}>
            {AH.format_pct(@mulligan_analytics.keep_rate)}
          </div>
          <div class="text-xs text-base-content/60">Keep Rate</div>
        </div>
        <div class="bg-base-200 rounded-lg p-4 text-center">
          <div class={"text-2xl font-bold #{DecksHelpers.win_rate_class(@mulligan_analytics.win_rate_on_7)}"}>
            {AH.format_pct(@mulligan_analytics.win_rate_on_7)}
          </div>
          <div class="text-xs text-base-content/60">Keep Rate on 7</div>
        </div>
      </div>

      <%!-- Heatmap: hand_size x land_count --%>
      <div class="mb-6">
        <h4 class="text-sm font-medium text-base-content/60 mb-2">
          Win Rate by Kept Hand Profile
          <span
            class="tooltip tooltip-right"
            data-tip="Shows your win rate for kept hands, grouped by hand size (rows) and number of lands (columns). Only includes hands you chose to keep."
          >
            <span class="text-base-content/40 cursor-help">(?)</span>
          </span>
        </h4>
        <div class="overflow-x-auto">
          <table class="table table-xs">
            <thead>
              <tr>
                <th class="text-base-content/40">Size \ Lands</th>
                <th :for={land <- 0..7} class="text-center text-base-content/40">{land}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={hand_size <- [7, 6, 5]}>
                <td class="text-base-content/60 font-medium">{hand_size} cards</td>
                <td :for={land <- 0..7} class="text-center p-1">
                  <% cell = AH.heatmap_cell(@mulligan_heatmap, hand_size, land) %>
                  <%= if cell do %>
                    <div class={"rounded px-2 py-1 text-xs font-medium #{AH.heatmap_cell_class(cell.win_rate)}"}>
                      <div>{AH.format_pct(cell.win_rate)}</div>
                      <div class="text-[10px] opacity-60">{cell.count}g</div>
                    </div>
                  <% else %>
                    <span class="text-base-content/20 text-xs">—</span>
                  <% end %>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <%!-- Win rate by land count bar breakdown --%>
      <div :if={@mulligan_analytics.by_land_count != []}>
        <h4 class="text-sm font-medium text-base-content/60 mb-2">
          Win Rate by Land Count (Kept Hands)
        </h4>
        <div class="flex items-end gap-2 h-32 px-2">
          <div
            :for={row <- @mulligan_analytics.by_land_count}
            class="flex-1 flex flex-col items-center gap-1"
          >
            <span class={"text-xs font-medium #{DecksHelpers.win_rate_class(row.win_rate)}"}>
              {AH.format_pct(row.win_rate)}
            </span>
            <div
              class={"w-full rounded-t #{land_count_bar_class(row.win_rate)}"}
              style={"height: #{land_count_bar_height(row.win_rate)}%"}
            >
            </div>
            <span class="text-xs text-base-content/50">{row.land_count}L</span>
            <span class="text-[10px] text-base-content/30">{row.total}g</span>
          </div>
        </div>
      </div>
    </section>

    <%!-- Card Performance Section --%>
    <section :if={@card_performance != []}>
      <div class="flex items-baseline justify-between mb-3">
        <h3 class="text-lg font-semibold">Card Performance</h3>
        <div class="flex items-center gap-1">
          <span class="text-xs text-base-content/40 mr-1">Sort:</span>
          <button
            :for={
              {key, label} <- [
                {:type, "Type"},
                {:iwd, "IWD"},
                {:gih_wr, "GIH WR"},
                {:oh_wr, "OH WR"},
                {:name, "Name"}
              ]
            }
            phx-click="sort_cards"
            phx-value-by={key}
            class={[
              "btn btn-xs",
              if(@card_sort == key, do: "btn-soft btn-primary", else: "btn-ghost")
            ]}
          >
            {label}
          </button>
        </div>
      </div>
      <p class="text-xs text-base-content/50 mb-3">
        Hover column headers for metric definitions.
        <span :if={Enum.any?(@card_performance, &AH.low_sample?(&1.gih_games))} class="text-warning">
          Metrics with &lt; 5 games dimmed.
        </span>
      </p>

      <div class="overflow-x-auto">
        <table class="table table-sm" style="max-width: 720px;">
          <thead>
            <tr>
              <th>Card</th>
              <th class="text-center">#</th>
              <th :for={{_key, metric} <- AH.metric_definitions()} class="text-center">
                <span class="tooltip tooltip-bottom" data-tip={metric.description}>
                  <span class="cursor-help border-b border-dotted border-base-content/30">
                    {metric.short}
                  </span>
                </span>
              </th>
            </tr>
          </thead>
          <tbody :for={
            {type_label, cards} <-
              AH.sort_cards(@card_performance, @cards_by_arena_id, @deck, @card_sort)
          }>
            <tr :if={type_label}>
              <td
                colspan="7"
                class="text-xs font-semibold text-base-content/40 uppercase tracking-wider pt-3 pb-0.5 border-b-0"
              >
                {type_label}
              </td>
            </tr>
            <tr
              :for={card <- cards}
              class={if AH.low_sample?(card.gih_games), do: "opacity-40"}
            >
              <td class="max-w-[160px] pr-0">
                <div class="truncate font-medium" title={card.card_name || "Unknown"}>
                  {card.card_name || "Unknown"}
                </div>
              </td>
              <td class="text-center text-base-content/50 px-1">{card.copies}</td>
              <td
                class={"text-center tabular-nums #{DecksHelpers.win_rate_class(card.oh_wr)}"}
                title={"#{card.oh_games} games"}
              >
                {AH.format_pct(card.oh_wr)}
              </td>
              <td
                class={"text-center tabular-nums #{DecksHelpers.win_rate_class(card.gih_wr)}"}
                title={"#{card.gih_games} games"}
              >
                {AH.format_pct(card.gih_wr)}
              </td>
              <td
                class={"text-center tabular-nums #{DecksHelpers.win_rate_class(card.gd_wr)}"}
                title={"#{card.gd_games} games"}
              >
                {AH.format_pct(card.gd_wr)}
              </td>
              <td
                class={"text-center tabular-nums #{DecksHelpers.win_rate_class(card.gnd_wr)}"}
                title={"#{card.gnd_games} games"}
              >
                {AH.format_pct(card.gnd_wr)}
              </td>
              <td class={"text-center tabular-nums font-semibold #{AH.iwd_class(card.iwd)}"}>
                {AH.format_iwd(card.iwd)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  defp land_count_bar_class(nil), do: "bg-base-300"
  defp land_count_bar_class(rate) when rate >= 55, do: "bg-success"
  defp land_count_bar_class(rate) when rate >= 45, do: "bg-warning"
  defp land_count_bar_class(_), do: "bg-error"

  defp land_count_bar_height(nil), do: 5
  defp land_count_bar_height(rate), do: max(5, round(rate))

  # ── Changes tab ────────────────────────────────────────────────────────

  attr :versions, :list, required: true
  attr :version_matches, :map, required: true
  attr :cards_by_arena_id, :map, required: true

  defp changes_tab(%{versions: []} = assigns) do
    ~H"""
    <.empty_state>No deck version history found.</.empty_state>
    """
  end

  defp changes_tab(assigns) do
    versions_with_prev =
      assigns.versions
      |> Enum.with_index()
      |> Enum.map(fn {version, index} ->
        # versions are newest-first, so "previous" is the next element
        previous = Enum.at(assigns.versions, index + 1)
        {version, previous}
      end)

    assigns = assign(assigns, :versions_with_prev, versions_with_prev)

    ~H"""
    <div class="relative pl-5">
      <%!-- Vertical timeline line --%>
      <div class="absolute left-[7px] top-2 bottom-2 w-0.5 bg-primary/30"></div>

      <%= for {{version, previous}, index} <- Enum.with_index(@versions_with_prev) do %>
        <%!-- Version entry --%>
        <div class="relative mb-6">
          <%!-- Timeline dot --%>
          <div class="absolute -left-5 top-1 w-3 h-3 rounded-full bg-primary"></div>

          <%!-- Version header --%>
          <div class="flex items-baseline justify-between mb-2">
            <div class="flex items-center gap-2">
              <span class="font-semibold text-sm">Version {version.version_number}</span>
              <span
                :if={version.version_number == 1}
                class="text-xs bg-base-300 px-1.5 py-0.5 rounded"
              >
                initial
              </span>
            </div>
            <span class="text-xs text-base-content/50">
              {DecksHelpers.format_version_date(version.occurred_at)}
            </span>
          </div>

          <%!-- Card diffs (only for versions after the first) --%>
          <.version_card_diffs
            :if={version.version_number > 1}
            version={version}
            cards_by_arena_id={@cards_by_arena_id}
          />

          <%!-- Initial version summary --%>
          <div :if={version.version_number == 1} class="text-xs text-base-content/50 mb-2">
            {DecksHelpers.deck_card_count(version.main_deck)} cards · First version of this deck
          </div>

          <%!-- Mana curve comparison (skip for version 1 without previous) --%>
          <.version_mana_curve
            :if={previous != nil}
            version={version}
            previous={previous}
            cards_by_arena_id={@cards_by_arena_id}
          />

          <%!-- Per-version stats --%>
          <.version_stats version={version} />
        </div>

        <%!-- Interleaved match summary between versions --%>
        <.version_match_summary
          :if={Map.has_key?(@version_matches, version.version_number)}
          matches={Map.get(@version_matches, version.version_number, [])}
          version_number={version.version_number}
          index={index}
        />
      <% end %>
    </div>
    """
  end

  attr :version, :map, required: true
  attr :cards_by_arena_id, :map, required: true

  defp version_card_diffs(assigns) do
    main_added = DecksHelpers.parse_diff_cards(assigns.version.main_deck_added)
    main_removed = DecksHelpers.parse_diff_cards(assigns.version.main_deck_removed)
    side_added = DecksHelpers.parse_diff_cards(assigns.version.sideboard_added)
    side_removed = DecksHelpers.parse_diff_cards(assigns.version.sideboard_removed)

    assigns =
      assign(assigns,
        main_added: main_added,
        main_removed: main_removed,
        side_added: side_added,
        side_removed: side_removed
      )

    ~H"""
    <div :if={@main_added != [] or @main_removed != []} class="flex gap-6 mb-2">
      <div :if={@main_added != []}>
        <div class="text-xs uppercase text-success tracking-wide mb-1 font-semibold">
          +{total_diff_count(@main_added)} Added
        </div>
        <div class="flex gap-1">
          <.card_diff_image
            :for={card <- @main_added}
            arena_id={card.arena_id}
            name={DecksHelpers.card_name(card.arena_id, @cards_by_arena_id)}
            count={card.count}
            kind={:added}
          />
        </div>
      </div>

      <div :if={@main_removed != []}>
        <div class="text-xs uppercase text-error tracking-wide mb-1 font-semibold">
          −{total_diff_count(@main_removed)} Removed
        </div>
        <div class="flex gap-1">
          <.card_diff_image
            :for={card <- @main_removed}
            arena_id={card.arena_id}
            name={DecksHelpers.card_name(card.arena_id, @cards_by_arena_id)}
            count={card.count}
            kind={:removed}
          />
        </div>
      </div>
    </div>

    <div :if={@side_added != [] or @side_removed != []} class="flex gap-4 mb-2 text-xs">
      <span class="text-base-content/40 uppercase tracking-wide">Sideboard</span>
      <span :if={@side_added != []} class="text-success">
        +{total_diff_count(@side_added)} card{if total_diff_count(@side_added) != 1, do: "s"}
      </span>
      <span :if={@side_removed != []} class="text-error">
        −{total_diff_count(@side_removed)} card{if total_diff_count(@side_removed) != 1, do: "s"}
      </span>
    </div>
    """
  end

  attr :version, :map, required: true

  defp version_stats(assigns) do
    total = assigns.version.match_wins + assigns.version.match_losses
    win_rate = if total > 0, do: Float.round(assigns.version.match_wins / total * 100, 1)

    on_play_total = assigns.version.on_play_wins + assigns.version.on_play_losses

    on_play_rate =
      if on_play_total > 0, do: Float.round(assigns.version.on_play_wins / on_play_total * 100, 1)

    on_draw_total = assigns.version.on_draw_wins + assigns.version.on_draw_losses

    on_draw_rate =
      if on_draw_total > 0, do: Float.round(assigns.version.on_draw_wins / on_draw_total * 100, 1)

    assigns =
      assign(assigns,
        total: total,
        win_rate: win_rate,
        on_play_rate: on_play_rate,
        on_draw_rate: on_draw_rate
      )

    ~H"""
    <div :if={@total > 0} class="flex gap-4 text-xs text-base-content/60">
      <span>
        {@version.match_wins}W–{@version.match_losses}L ·
        <span class={DecksHelpers.win_rate_class(@win_rate)}>
          {DecksHelpers.format_win_rate(@win_rate)}
        </span>
      </span>
      <span :if={@on_play_rate}>
        On play:
        <span class={DecksHelpers.win_rate_class(@on_play_rate)}>
          {DecksHelpers.format_win_rate(@on_play_rate)}
        </span>
      </span>
      <span :if={@on_draw_rate}>
        On draw:
        <span class={DecksHelpers.win_rate_class(@on_draw_rate)}>
          {DecksHelpers.format_win_rate(@on_draw_rate)}
        </span>
      </span>
    </div>
    <div :if={@total == 0} class="text-xs text-base-content/30">No matches</div>
    """
  end

  attr :version, :map, required: true
  attr :previous, :map, required: true
  attr :cards_by_arena_id, :map, required: true

  defp version_mana_curve(assigns) do
    curve_data =
      DecksHelpers.version_mana_curve_data(
        assigns.version,
        assigns.previous,
        assigns.cards_by_arena_id
      )

    max_val = curve_data |> Enum.flat_map(fn {_, b, a} -> [b, a] end) |> Enum.max(fn -> 1 end)
    assigns = assign(assigns, curve_data: curve_data, max_val: max_val)

    ~H"""
    <div class="inline-flex gap-1 items-end h-8 mb-2">
      <div :for={{label, prev_count, curr_count} <- @curve_data} class="flex flex-col items-center">
        <div class="flex gap-px items-end h-6">
          <div
            class="w-1.5 bg-error/50 rounded-t-sm"
            style={"height: #{bar_height(prev_count, @max_val)}px"}
          />
          <div
            class="w-1.5 bg-success rounded-t-sm"
            style={"height: #{bar_height(curr_count, @max_val)}px"}
          />
        </div>
        <span class="text-[0.55rem] text-base-content/30">{label}</span>
      </div>
    </div>
    """
  end

  attr :matches, :list, required: true
  attr :version_number, :integer, required: true
  attr :index, :integer, required: true

  defp version_match_summary(%{matches: []} = assigns) do
    ~H""
  end

  defp version_match_summary(assigns) do
    total = length(assigns.matches)
    wins = Enum.count(assigns.matches, & &1.won)
    losses = total - wins
    assigns = assign(assigns, total: total, wins: wins, losses: losses)

    ~H"""
    <div class="relative mb-6 pl-0">
      <details class="group">
        <summary class="text-xs text-base-content/35 cursor-pointer list-none flex items-center gap-1 hover:text-base-content/50">
          <span class="group-open:rotate-90 transition-transform">▸</span>
          <span>{@total} match{if @total != 1, do: "es"} played ({@wins}W–{@losses}L)</span>
        </summary>
        <div class="mt-2 space-y-1 ml-3">
          <div
            :for={match <- @matches}
            class="flex items-center gap-3 text-xs text-base-content/50"
          >
            <span class={if match.won, do: "text-success", else: "text-error"}>
              {if match.won, do: "W", else: "L"}
            </span>
            <span :if={match.event_name} class="truncate max-w-48">{match.event_name}</span>
            <span :if={match.player_rank}>{match.player_rank}</span>
            <span class="text-base-content/30">
              {DecksHelpers.format_date(match.started_at)}
            </span>
          </div>
        </div>
      </details>
    </div>
    """
  end

  # ── Private helpers ───────────────────────────────────────────────────────

  defp load_deck_detail(socket, deck, tab, format, page) do
    performance = Decks.get_deck_performance(deck.mtga_deck_id)
    match_count = performance.bo1.total + performance.bo3.total
    version_count = Decks.count_versions(deck.mtga_deck_id)

    {matches, matches_total, format_counts, active_format} =
      if tab == :matches do
        counts = Decks.match_counts_by_format(deck.mtga_deck_id)
        active_format = format || Decks.latest_format(deck.mtga_deck_id)
        offset = (page - 1) * 20

        {matches, total} =
          Decks.list_matches_for_deck(deck.mtga_deck_id,
            format: active_format,
            limit: 20,
            offset: offset
          )

        {matches, total, counts, active_format}
      else
        {[], 0, %{bo1: 0, bo3: 0}, nil}
      end

    {versions, version_matches} =
      if tab == :changes do
        {Decks.get_deck_versions(deck.mtga_deck_id),
         Decks.get_matches_by_version(deck.mtga_deck_id)}
      else
        {[], %{}}
      end

    {mulligan_analytics, mulligan_heatmap, card_performance} =
      if tab == :analysis do
        {
          Decks.mulligan_analytics(deck.mtga_deck_id),
          Decks.mulligan_heatmap(deck.mtga_deck_id),
          Decks.card_performance(deck.mtga_deck_id)
        }
      else
        {nil, [], []}
      end

    arena_ids = DecksAnalysisHelpers.arena_ids_for_page(deck, versions, card_performance)
    cards_by_arena_id = Cards.list_by_arena_ids(arena_ids)

    if connected?(socket) do
      ImageCache.ensure_cached(arena_ids)
    end

    total_pages = max(1, ceil(matches_total / 20))

    assign(socket,
      deck: deck,
      performance: performance,
      match_count: match_count,
      version_count: version_count,
      versions: versions,
      version_matches: version_matches,
      matches: matches,
      matches_total: matches_total,
      matches_page: page,
      matches_total_pages: total_pages,
      format_counts: format_counts,
      active_format: active_format,
      cards_by_arena_id: cards_by_arena_id,
      active_tab: tab,
      mulligan_analytics: mulligan_analytics,
      mulligan_heatmap: mulligan_heatmap,
      card_performance: card_performance
    )
  end

  defp total_diff_count(cards), do: Enum.sum(Enum.map(cards, & &1.count))

  defp bar_height(_count, 0), do: 2
  defp bar_height(count, max_val), do: max(2, round(count / max_val * 24))

  defp parse_tab("analysis"), do: :analysis
  defp parse_tab("matches"), do: :matches
  defp parse_tab("changes"), do: :changes
  defp parse_tab(_), do: :overview

  defp parse_format("bo1"), do: :bo1
  defp parse_format("bo3"), do: :bo3
  defp parse_format(_), do: nil

  defp parse_page(nil), do: 1

  defp parse_page(p) when is_binary(p) do
    case Integer.parse(p) do
      {n, _} when n > 0 -> n
      _ -> 1
    end
  end

  defp parse_deck_filter("all"), do: :all
  defp parse_deck_filter(_), do: :played
end
