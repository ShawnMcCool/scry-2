defmodule Scry2Web.DraftsLive do
  @moduledoc """
  LiveView for the drafts dashboard, filtered draft list, and draft detail.

  List view (`:list`) displays a stats dashboard (stat cards, format breakdown
  bar chart) above a filtered draft table. Filters (format, set) are URL params.

  Detail view (`:detail`) displays a draft header with record/trophy/status,
  and three tabs: Picks, Deck, and Matches.
  """
  use Scry2Web, :live_view

  alias Scry2.Cards
  alias Scry2.Cards.ImageCache
  alias Scry2.Drafts
  alias Scry2.Matches
  alias Scry2.Topics
  alias Scry2Web.DraftsHelpers

  # ── Lifecycle ────────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Topics.subscribe(Topics.drafts_updates())
    {:ok, assign(socket, reload_timer: nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    player_id = socket.assigns[:active_player_id]

    case params do
      %{"id" => id} ->
        tab = parse_tab(params["tab"])
        draft = Drafts.get_draft_with_picks(String.to_integer(id))

        if draft do
          {:noreply, assign_detail(socket, draft, tab, player_id)}
        else
          {:noreply, push_navigate(socket, to: ~p"/drafts")}
        end

      _ ->
        {:noreply, assign_list(socket, params, player_id)}
    end
  end

  @impl true
  def handle_info({:draft_updated, _}, socket) do
    {:noreply, schedule_reload(socket)}
  end

  def handle_info(:reload_data, socket) do
    player_id = socket.assigns[:active_player_id]

    socket =
      case socket.assigns[:page] do
        :detail ->
          draft = Drafts.get_draft_with_picks(socket.assigns.draft.id)
          tab = socket.assigns[:active_tab] || :picks
          assign_detail(socket, draft, tab, player_id)

        _ ->
          assign_list(socket, list_filter_params(socket), player_id)
      end

    {:noreply, assign(socket, reload_timer: nil)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # ── Data loading ─────────────────────────────────────────────────────

  defp assign_list(socket, params, player_id) do
    format = params["format"]
    set_code = params["set"]
    stats = Drafts.draft_stats(player_id: player_id)

    drafts =
      Drafts.list_drafts(
        player_id: player_id,
        format: format,
        set_code: set_code,
        limit: 50
      )

    set_codes = Drafts.list_set_codes(player_id: player_id)

    assign(socket,
      page: :list,
      stats: stats,
      drafts: drafts,
      format_filter: format,
      set_filter: set_code,
      available_sets: set_codes
    )
  end

  defp assign_detail(socket, draft, tab, player_id) do
    base =
      assign(socket,
        page: :detail,
        draft: draft,
        active_tab: tab,
        cards_by_arena_id: %{},
        card_pool_groups: [],
        submitted_decks: [],
        event_matches: []
      )

    case tab do
      :picks ->
        arena_ids = all_pack_arena_ids(draft)
        cards_by_arena_id = Cards.list_by_arena_ids(arena_ids)
        if connected?(socket), do: ImageCache.ensure_cached(arena_ids)
        assign(base, cards_by_arena_id: cards_by_arena_id)

      :deck ->
        pool_ids = pool_arena_ids(draft)
        cards_by_arena_id = Cards.list_by_arena_ids(pool_ids)
        if connected?(socket), do: ImageCache.ensure_cached(pool_ids)
        groups = DraftsHelpers.group_pool_by_type(pool_ids, cards_by_arena_id)

        decks =
          if draft,
            do: Matches.list_decks_for_event(draft.event_name, player_id),
            else: []

        assign(base,
          card_pool_groups: groups,
          cards_by_arena_id: cards_by_arena_id,
          submitted_decks: decks
        )

      :matches ->
        event_matches =
          if draft,
            do: Matches.list_matches_for_event(draft.event_name, player_id),
            else: []

        assign(base, event_matches: event_matches)
    end
  end

  defp list_filter_params(socket) do
    %{
      "format" => socket.assigns[:format_filter],
      "set" => socket.assigns[:set_filter]
    }
  end

  # ── List render ─────────────────────────────────────────────────────

  @impl true
  def render(%{page: :list} = assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app
      flash={@flash}
      players={@players}
      active_player_id={@active_player_id}
      current_path={@player_scope_uri}
    >
      <h1 class="text-2xl font-semibold font-beleren">Drafts</h1>

      <div class="grid grid-cols-2 sm:grid-cols-4 gap-3 mt-4">
        <.stat_card title="Total Drafts" value={@stats.total} data-stat="total-drafts" />
        <.stat_card
          title="Win Rate"
          value={if @stats.win_rate, do: "#{round(@stats.win_rate * 100)}%", else: "—"}
        />
        <.stat_card
          title="Avg Wins"
          value={
            if @stats.avg_wins,
              do: @stats.avg_wins |> Float.round(1) |> to_string(),
              else: "—"
          }
        />
        <.stat_card title="Trophies" value={@stats.trophies} data-stat="trophies" />
      </div>

      <div :if={@stats.by_format != []} class="card bg-base-200 mt-3 p-4">
        <div class="text-xs font-medium text-base-content/40 uppercase tracking-wide mb-3">
          By Format
        </div>
        <div class="flex flex-col gap-2">
          <div :for={row <- @stats.by_format} class="flex items-center gap-3">
            <span class="text-sm w-36 shrink-0">{DraftsHelpers.format_label(row.format)}</span>
            <div class="flex-1 bg-base-300 rounded-full h-1.5 overflow-hidden">
              <div
                class={["h-full rounded-full", format_bar_color(row.win_rate)]}
                style={"width: #{round((row.win_rate || 0) * 100)}%"}
              />
            </div>
            <span class={[
              "text-xs w-20 text-right tabular-nums",
              format_win_rate_color(row.win_rate)
            ]}>
              {if row.win_rate, do: "#{round(row.win_rate * 100)}%", else: "—"} ({row.total})
            </span>
          </div>
        </div>
      </div>

      <div class="flex flex-wrap items-center gap-2 mt-4" data-filter="format">
        <.link
          patch={~p"/drafts"}
          class={[
            "btn btn-xs",
            if(is_nil(@format_filter), do: "btn-soft btn-primary", else: "btn-ghost")
          ]}
        >
          All Formats
        </.link>
        <.link
          :for={fmt <- ~w(quick_draft premier_draft traditional_draft)}
          patch={
            if @set_filter,
              do: ~p"/drafts?format=#{fmt}&set=#{@set_filter}",
              else: ~p"/drafts?format=#{fmt}"
          }
          class={[
            "btn btn-xs",
            if(@format_filter == fmt, do: "btn-soft btn-primary", else: "btn-ghost")
          ]}
        >
          {DraftsHelpers.format_label(fmt)}
        </.link>
        <div class="flex-1" />
        <.link
          :for={set <- @available_sets}
          patch={
            if @format_filter,
              do: ~p"/drafts?set=#{set}&format=#{@format_filter}",
              else: ~p"/drafts?set=#{set}"
          }
          class={[
            "btn btn-xs",
            if(@set_filter == set, do: "btn-soft btn-primary", else: "btn-ghost")
          ]}
        >
          {set}
        </.link>
      </div>

      <.empty_state :if={@drafts == []}>No drafts recorded yet.</.empty_state>

      <div :if={@drafts != []} class="overflow-x-auto mt-3">
        <table class="table table-sm table-zebra">
          <thead>
            <tr class="text-xs text-base-content/60 uppercase">
              <th>Date</th>
              <th>Set</th>
              <th>Format</th>
              <th>Record</th>
              <th>Status</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={draft <- @drafts}
              class="hover cursor-pointer"
              data-format={draft.format}
              phx-click={JS.navigate(~p"/drafts/#{draft.id}")}
            >
              <td>{format_datetime(draft.started_at)}</td>
              <td>{draft.set_code || "—"}</td>
              <td class="text-base-content/60">{DraftsHelpers.format_label(draft.format)}</td>
              <td>
                <span class={["font-semibold tabular-nums", DraftsHelpers.record_color_class(draft)]}>
                  {DraftsHelpers.win_loss_label(draft.wins, draft.losses)}
                </span>
                <span :if={DraftsHelpers.trophy?(draft)} class="ml-1 badge badge-xs badge-warning">
                  Trophy
                </span>
              </td>
              <td class={[
                "text-xs",
                if(is_nil(draft.completed_at), do: "text-warning", else: "text-success")
              ]}>
                {DraftsHelpers.draft_status_label(draft)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end

  # ── Detail render ───────────────────────────────────────────────────

  def render(%{page: :detail} = assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app
      flash={@flash}
      players={@players}
      active_player_id={@active_player_id}
      current_path={@player_scope_uri}
    >
      <.back_link navigate={~p"/drafts"} label="All drafts" />

      <div class="mt-2">
        <h1 class="text-2xl font-semibold font-beleren">
          {@draft.set_code} {DraftsHelpers.format_label(@draft.format)}
        </h1>
        <div class="flex items-center gap-3 mt-1">
          <span class={[
            "text-2xl font-black tabular-nums",
            DraftsHelpers.record_color_class(@draft)
          ]}>
            {DraftsHelpers.win_loss_label(@draft.wins, @draft.losses)}
          </span>
          <span :if={DraftsHelpers.trophy?(@draft)} class="badge badge-warning">Trophy</span>
          <span class="text-sm text-base-content/50">{format_datetime(@draft.started_at)}</span>
          <span
            :if={is_nil(@draft.completed_at)}
            class="badge badge-warning badge-outline badge-sm"
          >
            In Progress
          </span>
        </div>
      </div>

      <div class="flex gap-0 border-b border-base-300 mt-4 mb-5">
        <.tab_link label="Picks" tab={:picks} active={@active_tab} draft={@draft} />
        <.tab_link label="Deck" tab={:deck} active={@active_tab} draft={@draft} />
        <.tab_link label="Matches" tab={:matches} active={@active_tab} draft={@draft} />
      </div>

      <.picks_tab
        :if={@active_tab == :picks}
        draft={@draft}
        cards_by_arena_id={@cards_by_arena_id}
      />
      <.deck_tab
        :if={@active_tab == :deck}
        draft={@draft}
        card_pool_groups={@card_pool_groups}
        cards_by_arena_id={@cards_by_arena_id}
        submitted_decks={@submitted_decks}
      />
      <.matches_tab :if={@active_tab == :matches} matches={@event_matches} />
    </Layouts.app>
    """
  end

  # ── Components ──────────────────────────────────────────────────────

  attr :label, :string, required: true
  attr :tab, :atom, required: true
  attr :active, :atom, required: true
  attr :draft, :map, required: true

  defp tab_link(assigns) do
    ~H"""
    <.link
      patch={~p"/drafts/#{@draft.id}?tab=#{@tab}"}
      class={[
        "px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors",
        if(@tab == @active,
          do: "border-primary text-primary",
          else: "border-transparent text-base-content/50 hover:text-base-content"
        )
      ]}
    >
      {@label}
    </.link>
    """
  end

  attr :draft, :map, required: true
  attr :cards_by_arena_id, :map, required: true

  defp picks_tab(assigns) do
    grouped =
      (assigns.draft.picks || [])
      |> Enum.group_by(&{&1.pack_number, &1.pick_number})
      |> Enum.sort_by(fn {{pack, pick}, _} -> {pack, pick} end)

    assigns = assign(assigns, :grouped_picks, grouped)

    ~H"""
    <.empty_state :if={@draft.picks == []}>No picks recorded yet.</.empty_state>

    <div :for={{{pack_num, pick_num}, [pick | _]} <- @grouped_picks} class="mb-8">
      <div
        class="text-xs font-medium text-base-content/40 uppercase tracking-widest mb-3"
        data-pack={"#{pack_num}-#{pick_num}"}
      >
        Pack {pack_num} · Pick {pick_num}
      </div>
      <p
        :if={(pick.pack_arena_ids["cards"] || []) == [] and not is_nil(pick.picked_arena_id)}
        class="text-xs text-base-content/40 italic mb-2"
      >
        Pack contents unavailable for this pick.
      </p>
      <div class="flex flex-wrap gap-2">
        <div
          :for={{arena_id, idx} <- Enum.with_index(pick.pack_arena_ids["cards"] || [])}
          class="relative"
        >
          <.card_image
            id={"pick-#{pick.draft_id}-#{pack_num}-#{pick_num}-#{idx}-#{arena_id}"}
            arena_id={arena_id}
            name={card_name(@cards_by_arena_id, arena_id)}
            class={
              if(arena_id == pick.picked_arena_id,
                do: "w-[72px] ring-2 ring-primary rounded-[5px]",
                else: "w-[72px] opacity-40"
              )
            }
            data-picked={if arena_id == pick.picked_arena_id, do: to_string(arena_id)}
          />
          <div
            :if={arena_id == pick.picked_arena_id}
            class="absolute top-1 right-1 w-5 h-5 rounded-full bg-primary flex items-center justify-center pointer-events-none"
          >
            <.icon name="hero-check-micro" class="w-3 h-3 text-primary-content" />
          </div>
        </div>
        <div
          :if={(pick.pack_arena_ids["cards"] || []) == [] and not is_nil(pick.picked_arena_id)}
          class="relative"
        >
          <.card_image
            id={"pick-solo-#{pick.draft_id}-#{pack_num}-#{pick_num}"}
            arena_id={pick.picked_arena_id}
            name={card_name(@cards_by_arena_id, pick.picked_arena_id)}
            class="w-[72px] ring-2 ring-primary rounded-[5px]"
            data-picked={to_string(pick.picked_arena_id)}
          />
          <div class="absolute top-1 right-1 w-5 h-5 rounded-full bg-primary flex items-center justify-center pointer-events-none">
            <.icon name="hero-check-micro" class="w-3 h-3 text-primary-content" />
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :draft, :map, required: true
  attr :card_pool_groups, :list, required: true
  attr :cards_by_arena_id, :map, required: true
  attr :submitted_decks, :list, required: true

  defp deck_tab(assigns) do
    ~H"""
    <div data-section="submitted-decks">
      <h3 class="text-xs font-medium text-base-content/40 uppercase tracking-wide mb-3">
        Submitted Decks
      </h3>
      <.empty_state :if={@submitted_decks == []}>
        No match data yet — decks appear after the first match is played.
      </.empty_state>
      <div class="flex flex-col gap-2 mb-8">
        <.link
          :for={deck <- @submitted_decks}
          navigate={~p"/decks/#{deck.mtga_deck_id}"}
          class="card bg-base-200 hover:bg-base-300 transition-colors cursor-pointer"
          data-deck={deck.mtga_deck_id}
        >
          <div class="card-body py-3 px-4">
            <div class="flex items-center justify-between">
              <div>
                <div class="font-medium">{deck.deck_name || deck.mtga_deck_id}</div>
                <div class="text-xs text-base-content/50 mt-0.5">
                  <.mana_pips colors={deck.deck_colors} class="text-[0.65rem]" />
                </div>
              </div>
              <.icon name="hero-arrow-right-micro" class="w-4 h-4 text-base-content/30" />
            </div>
          </div>
        </.link>
      </div>
    </div>
    <div data-section="draft-pool">
      <h3 class="text-xs font-medium text-base-content/40 uppercase tracking-wide mb-3">
        Full Draft Pool
      </h3>
      <.empty_state :if={@card_pool_groups == []}>
        Pool available after the draft is complete.
      </.empty_state>
      <div class="flex flex-wrap gap-8">
        <div :for={{type_label, arena_ids} <- @card_pool_groups}>
          <div class="text-xs font-medium text-base-content/40 uppercase tracking-wide mb-2">
            {type_label} ({length(arena_ids)})
          </div>
          <div class="flex gap-1 flex-wrap">
            <.card_image
              :for={{arena_id, idx} <- Enum.with_index(arena_ids)}
              id={"pool-#{@draft.id}-#{arena_id}-#{idx}"}
              arena_id={arena_id}
              name={card_name(@cards_by_arena_id, arena_id)}
              class="w-[56px]"
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :matches, :list, required: true

  defp matches_tab(assigns) do
    ~H"""
    <.empty_state :if={@matches == []}>No matches recorded for this draft yet.</.empty_state>
    <div :if={@matches != []} class="overflow-x-auto">
      <table class="table table-sm">
        <thead>
          <tr class="text-xs text-base-content/60 uppercase">
            <th>Result</th>
            <th>Opponent</th>
            <th>Deck</th>
            <th>Date</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={match <- @matches}
            class="hover cursor-pointer"
            data-match={match.id}
            phx-click={JS.navigate(~p"/matches/#{match.id}")}
          >
            <td>
              <span class={if match.won, do: "font-bold text-success", else: "font-bold text-error"}>
                {if match.won, do: "W", else: "L"}
              </span>
            </td>
            <td>
              <div>{match.opponent_screen_name || "—"}</div>
              <div :if={match.opponent_rank} class="flex items-center gap-1 mt-0.5">
                <.rank_icon
                  rank={match.opponent_rank}
                  format_type={match.format_type || "Limited"}
                  class="h-3"
                />
                <span class="text-xs text-base-content/40">{match.opponent_rank}</span>
              </div>
            </td>
            <td>
              <.link
                :if={match.mtga_deck_id}
                navigate={~p"/decks/#{match.mtga_deck_id}"}
                class="link link-hover text-sm"
                data-deck-link={match.mtga_deck_id}
              >
                {match.deck_name || match.mtga_deck_id}
              </.link>
              <span :if={is_nil(match.mtga_deck_id)} class="text-base-content/40 text-sm">—</span>
            </td>
            <td class="text-sm text-base-content/50">{format_datetime(match.started_at)}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  # ── Private helpers ─────────────────────────────────────────────────

  defp parse_tab("deck"), do: :deck
  defp parse_tab("matches"), do: :matches
  defp parse_tab(_), do: :picks

  defp all_pack_arena_ids(nil), do: []

  defp all_pack_arena_ids(%{picks: picks}) do
    picks
    |> Enum.flat_map(fn pick ->
      picked = if pick.picked_arena_id, do: [pick.picked_arena_id], else: []
      pack = (pick.pack_arena_ids || %{})["cards"] || []
      picked ++ pack
    end)
    |> Enum.uniq()
  end

  defp pool_arena_ids(nil), do: []
  defp pool_arena_ids(%{card_pool_arena_ids: %{"ids" => ids}}) when is_list(ids), do: ids
  defp pool_arena_ids(_), do: []

  defp card_name(cards_by_arena_id, arena_id) do
    case Map.get(cards_by_arena_id, arena_id) do
      nil -> ""
      %{name: name} -> name
      card -> Map.get(card, :name, "")
    end
  end

  defp format_bar_color(nil), do: "bg-error"
  defp format_bar_color(rate), do: "bg-#{DraftsHelpers.win_rate_color(rate)}"

  defp format_win_rate_color(nil), do: "text-error"
  defp format_win_rate_color(rate), do: "text-#{DraftsHelpers.win_rate_color(rate)}"
end
