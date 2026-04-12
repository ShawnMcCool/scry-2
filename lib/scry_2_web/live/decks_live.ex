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
       evolution: [],
       matches: [],
       cards_by_arena_id: %{},
       active_tab: :overview,
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
      socket = load_deck_detail(socket, deck, tab)
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
          |> load_deck_detail(fresh_deck, socket.assigns.active_tab)
          |> assign(reload_timer: nil)
      end

    {:noreply, socket}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(%{deck: nil} = assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app flash={@flash} players={@players} active_player_id={@active_player_id}>
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
    <Layouts.app flash={@flash} players={@players} active_player_id={@active_player_id}>
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
            />
          </div>
        </div>
      </div>

      <%!-- Tabs --%>
      <div role="tablist" class="tabs tabs-border mb-6">
        <.tab_link label="Overview" tab={:overview} active={@active_tab} deck={@deck} />
        <.tab_link label="Matches" tab={:matches} active={@active_tab} deck={@deck} />
        <.tab_link label="Changes" tab={:changes} active={@active_tab} deck={@deck} />
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
          <.matches_tab matches={@matches} />
        <% :changes -> %>
          <.changes_tab evolution={@evolution} />
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

  defp tab_link(assigns) do
    ~H"""
    <a
      role="tab"
      class={["tab", @active == @tab && "tab-active"]}
      phx-click="switch_tab"
      phx-value-tab={@tab}
    >
      {@label}
    </a>
    """
  end

  attr :performance, :map, required: true
  attr :deck, :map, required: true
  attr :cards_by_arena_id, :map, required: true

  defp overview_tab(assigns) do
    card_groups = DecksHelpers.group_deck_cards(assigns.deck, assigns.cards_by_arena_id)
    cmc_columns = DecksHelpers.group_cards_by_cmc(assigns.deck, assigns.cards_by_arena_id)
    sideboard = DecksHelpers.sideboard_cards(assigns.deck, assigns.cards_by_arena_id)

    assigns =
      assign(assigns, card_groups: card_groups, cmc_columns: cmc_columns, sideboard: sideboard)

    ~H"""
    <div class="space-y-10">
      <%!-- Performance --%>
      <.performance_section performance={@performance} />

      <%!-- Composition + Sideboard --%>
      <div :if={@card_groups != []}>
        <div class="flex gap-6 items-start">
          <%!-- Left sidebar: mana curve + card list by type --%>
          <div class="w-52 flex-shrink-0 space-y-4">
            <div
              id="deck-curve-chart"
              phx-hook="Chart"
              data-chart-type="curve"
              data-series={DecksHelpers.mana_curve_series(@deck, @cards_by_arena_id)}
              class="w-full rounded-lg bg-base-200"
              style="height: 5rem"
            />

            <div class="space-y-4">
              <div :for={{type_label, cards} <- @card_groups}>
                <h3 class="text-xs font-medium text-base-content/40 uppercase tracking-wide mb-1">
                  {type_label} ({Enum.sum(Enum.map(cards, & &1.count))})
                </h3>
                <div class="space-y-0.5">
                  <div
                    :for={card <- cards}
                    id={"card-row-#{card.arena_id}"}
                    class="flex items-center gap-2 text-sm py-0.5 cursor-default"
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
          </div>

          <%!-- Right: card images + sideboard below --%>
          <div class="flex flex-col flex-1 min-w-0">
            <div class="flex gap-3 items-start overflow-x-auto pb-4" data-deck-grid>
              <div :for={{cmc_label, cards} <- @cmc_columns} class="flex flex-col items-center">
                <p class="text-xs text-base-content/30 mb-1">{cmc_label}</p>
                <div class="flex flex-col">
                  <div
                    :for={{card, index} <- Enum.with_index(cards)}
                    class={["relative", if(index > 0, do: "-mt-[7rem]")]}
                  >
                    <.card_image
                      id={"card-grid-#{card.arena_id}"}
                      arena_id={card.arena_id}
                      name={card.name}
                      class="w-28"
                    />
                    <span class="absolute top-1 right-1 rounded bg-black/70 px-1 text-xs font-bold text-white pointer-events-none">
                      {card.count}/4
                    </span>
                  </div>
                </div>
              </div>
            </div>

            <%!-- Sideboard: horizontal splay below main deck cards --%>
            <.sideboard_splay :if={@sideboard != []} cards={@sideboard} />
          </div>
        </div>
      </div>

      <.empty_state :if={@card_groups == []}>
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
    <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
      <.stats_panel
        title="Best-of-1"
        stats={@performance.bo1}
        format={:bo1}
        win_rate_by_week={@performance.win_rate_by_week}
      />
      <.stats_panel
        title="Best-of-3"
        stats={@performance.bo3}
        format={:bo3}
        win_rate_by_week={@performance.win_rate_by_week}
      />
    </div>
    """
  end

  attr :cards, :list, required: true

  defp sideboard_splay(assigns) do
    total = Enum.sum(Enum.map(assigns.cards, & &1.count))
    assigns = assign(assigns, total: total)

    ~H"""
    <div id="sideboard-splay" phx-hook="SideboardSplay" class="mt-8">
      <h3 class="text-xs font-medium text-base-content/40 uppercase tracking-wide mb-3">
        Sideboard ({@total})
      </h3>
      <div data-splay-container class="flex items-end pb-4">
        <div :for={card <- @cards} class="relative flex-shrink-0">
          <.card_image
            id={"sideboard-#{card.arena_id}"}
            arena_id={card.arena_id}
            name={card.name}
            class="w-28"
          />
          <span class="absolute bottom-1 left-1 rounded bg-black/70 px-1 text-xs font-bold text-white pointer-events-none">
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
  attr :win_rate_by_week, :list, default: []

  defp stats_panel(assigns) do
    chart_series =
      case assigns.format do
        :bo1 -> DecksHelpers.bo1_winrate_series(assigns.win_rate_by_week)
        :bo3 -> DecksHelpers.bo3_winrate_series(assigns.win_rate_by_week)
      end

    assigns = assign(assigns, :chart_series, chart_series)

    ~H"""
    <div class="bg-base-200 rounded-xl p-5 flex gap-4">
      <div class="flex flex-col gap-3 w-44 shrink-0">
        <h3 class="text-xs font-semibold text-base-content/40 uppercase tracking-widest">
          {@title}
        </h3>
        <.stats_body stats={@stats} format={@format} />
      </div>
      <div
        id={"deck-winrate-#{@format}"}
        phx-hook="Chart"
        data-chart-type="winrate"
        data-series={@chart_series}
        class="flex-1 min-w-0 rounded-lg bg-base-300/40"
      />
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
      <div class="grid grid-cols-2 gap-x-2 gap-y-2 text-sm">
        <.stat_row
          label="On Play"
          value={DecksHelpers.format_win_rate(@stats.on_play_win_rate)}
          sub={
            DecksHelpers.record_str(@stats.on_play_wins, @stats.on_play_total - @stats.on_play_wins)
          }
        />
        <.stat_row
          label="On Draw"
          value={DecksHelpers.format_win_rate(@stats.on_draw_win_rate)}
          sub={
            DecksHelpers.record_str(@stats.on_draw_wins, @stats.on_draw_total - @stats.on_draw_wins)
          }
        />
        <.stat_row
          :if={@format == :bo3}
          label="Game 1"
          value={DecksHelpers.format_win_rate(@stats[:game1_win_rate])}
          sub={
            DecksHelpers.record_str(@stats[:game1_wins], @stats[:game1_total] - @stats[:game1_wins])
          }
        />
        <.stat_row
          :if={@format == :bo3}
          label="Games 2–3"
          value={DecksHelpers.format_win_rate(@stats[:games_2_3_win_rate])}
          sub={
            DecksHelpers.record_str(
              @stats[:games_2_3_wins],
              @stats[:games_2_3_total] - @stats[:games_2_3_wins]
            )
          }
        />
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :sub, :string, default: nil

  defp stat_row(assigns) do
    ~H"""
    <div>
      <div class="text-base-content/50 text-xs">{@label}</div>
      <div class="font-medium">
        {@value} <span :if={@sub} class="text-xs text-base-content/50">{@sub}</span>
      </div>
    </div>
    """
  end

  attr :matches, :list, required: true

  defp matches_tab(%{matches: []} = assigns) do
    ~H"""
    <.empty_state>No matches recorded for this deck yet.</.empty_state>
    """
  end

  defp matches_tab(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="table table-zebra w-full">
        <thead>
          <tr class="text-xs text-base-content/60 uppercase">
            <th>Date</th>
            <th>Result</th>
            <th>Format</th>
            <th>Event</th>
            <th>Rank</th>
            <th class="text-center">Games</th>
            <th class="text-center">On Play</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={match <- @matches}>
            <td class="text-sm text-base-content/60 tabular-nums">
              {DecksHelpers.format_date(match.started_at)}
            </td>
            <td>
              <span class={
                if match.won, do: "text-success font-semibold", else: "text-error font-semibold"
              }>
                {if match.won, do: "Win", else: "Loss"}
              </span>
            </td>
            <td class="text-sm text-base-content/70">
              {if match.format_type == "Traditional", do: "BO3", else: "BO1"}
            </td>
            <td class="text-sm text-base-content/70">{match.event_name || "—"}</td>
            <td class="text-sm text-base-content/70">{match.player_rank || "—"}</td>
            <td class="text-center text-sm">{match.num_games || "—"}</td>
            <td class="text-center text-sm">
              {case match.on_play do
                true -> "Play"
                false -> "Draw"
                nil -> "—"
              end}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  attr :evolution, :list, required: true

  defp changes_tab(%{evolution: []} = assigns) do
    ~H"""
    <.empty_state>No deck update history found.</.empty_state>
    """
  end

  defp changes_tab(assigns) do
    ~H"""
    <div class="space-y-4">
      <div :for={event <- @evolution} class="bg-base-200 rounded-xl p-4">
        <div class="flex items-center justify-between mb-2">
          <span class="font-medium text-sm">{event.deck_name || "Deck updated"}</span>
          <span class="text-xs text-base-content/50">
            {DecksHelpers.format_date(event.occurred_at)}
          </span>
        </div>
        <div class="text-xs text-base-content/50">
          {event.action_type} — {length(event.main_deck)} unique cards in main deck
        </div>
      </div>
    </div>
    """
  end

  # ── Private helpers ───────────────────────────────────────────────────────

  defp load_deck_detail(socket, deck, tab) do
    performance = Decks.get_deck_performance(deck.mtga_deck_id)
    evolution = if tab == :changes, do: Decks.get_deck_evolution(deck.mtga_deck_id), else: []
    matches = if tab == :matches, do: Decks.list_matches_for_deck(deck.mtga_deck_id), else: []
    arena_ids = collect_arena_ids(deck)
    cards_by_arena_id = Cards.list_by_arena_ids(arena_ids)

    if connected?(socket) do
      ImageCache.ensure_cached(arena_ids)
    end

    assign(socket,
      deck: deck,
      performance: performance,
      evolution: evolution,
      matches: matches,
      cards_by_arena_id: cards_by_arena_id,
      active_tab: tab
    )
  end

  defp collect_arena_ids(deck) do
    (extract_card_ids(deck.current_main_deck) ++ extract_card_ids(deck.current_sideboard))
    |> Enum.uniq()
    |> Enum.filter(&is_integer/1)
  end

  defp extract_card_ids(%{"cards" => cards}), do: Enum.map(cards, &card_arena_id/1)
  defp extract_card_ids(_), do: []

  defp card_arena_id(%{"arena_id" => id}), do: id
  defp card_arena_id(%{arena_id: id}), do: id
  defp card_arena_id(_), do: nil

  defp parse_tab("matches"), do: :matches
  defp parse_tab("changes"), do: :changes
  defp parse_tab(_), do: :overview

  defp parse_deck_filter("all"), do: :all
  defp parse_deck_filter(_), do: :played
end
