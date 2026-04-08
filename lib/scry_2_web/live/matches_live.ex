defmodule Scry2Web.MatchesLive do
  @moduledoc """
  LiveView for the matches list and match detail pages.

  List view (`:index`) uses the `MatchListing` projection for precomputed
  display data — opponent info, game score, deck colors, duration. Detail
  view (`:show`) uses `Matches.get_match_with_associations/1` which loads
  the full match with per-game records.
  """
  use Scry2Web, :live_view

  alias Scry2.MatchListing
  alias Scry2.Matches
  alias Scry2.Topics
  alias Scry2Web.MatchesHelpers

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Topics.subscribe(Topics.matches_updates())

    {:ok, assign(socket, matches: [], match: nil, reload_timer: nil)}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    match = Matches.get_match_with_associations(String.to_integer(id))
    {:noreply, assign(socket, match: match, matches: [])}
  end

  def handle_params(_params, _uri, socket) do
    player_id = socket.assigns[:active_player_id]

    {:noreply,
     assign(socket,
       matches: MatchListing.list_matches(limit: 100, player_id: player_id),
       match: nil
     )}
  end

  @impl true
  def handle_info({:match_updated, _}, socket) do
    {:noreply, schedule_reload(socket)}
  end

  def handle_info(:reload_data, socket) do
    player_id = socket.assigns[:active_player_id]

    {:noreply,
     assign(socket,
       matches: MatchListing.list_matches(limit: 100, player_id: player_id),
       reload_timer: nil
     )}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(%{match: nil} = assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app flash={@flash} players={@players} active_player_id={@active_player_id}>
      <h1 class="text-2xl font-semibold mb-6">Matches</h1>

      <.empty_state :if={@matches == []}>
        No matches recorded yet. Play a game with MTGA detailed logs enabled to see entries here.
      </.empty_state>

      <div :if={@matches != []} class="flex flex-col divide-y divide-base-content/5">
        <div
          :for={match <- @matches}
          class="flex items-center gap-5 py-4 cursor-pointer hover:bg-base-content/3 rounded-lg px-2 -mx-2 transition-colors"
          phx-click={JS.navigate(~p"/matches/#{match.id}")}
        >
          <%!-- Result indicator --%>
          <div class={[
            "text-3xl font-black w-8 text-center shrink-0 tabular-nums",
            MatchesHelpers.result_letter_class(match.won)
          ]}>
            {MatchesHelpers.result_letter(match.won)}
          </div>

          <%!-- Main content --%>
          <div class="flex flex-col gap-1 min-w-0 flex-1">
            <%!-- Top line: opponent · colors · format --%>
            <div class="flex items-center gap-3 flex-wrap">
              <span class="font-semibold text-base-content truncate">
                {match.opponent_screen_name || "Unknown Opponent"}
              </span>

              <.rank_icon
                :if={match.opponent_rank}
                rank={match.opponent_rank}
                format_type={match.format_type || "Limited"}
                class="h-6"
              />

              <span :if={match.deck_colors && match.deck_colors != ""} class="flex gap-0.5">
                <.mana_pips colors={match.deck_colors} />
              </span>

              <span class="badge badge-sm badge-ghost shrink-0">
                {format_label(match.format)}
              </span>
            </div>

            <%!-- Bottom line: timestamp · score · play/draw · mulligans · turns --%>
            <div class="flex items-center gap-3 text-xs text-base-content/45 flex-wrap">
              <span class="tabular-nums">
                {MatchesHelpers.format_match_datetime(match.started_at)}
              </span>

              <span :if={match.num_games && match.num_games > 0} class="tabular-nums">
                {MatchesHelpers.game_score(match.game_results, match.won)}
              </span>

              <span :if={match.on_play != nil}>
                {MatchesHelpers.on_play_label(match.on_play)}
              </span>

              <span :if={match.total_mulligans && match.total_mulligans > 0}>
                {match.total_mulligans} {if match.total_mulligans == 1,
                  do: "mulligan",
                  else: "mulligans"}
              </span>

              <span :if={match.total_turns && match.total_turns > 0} class="tabular-nums">
                {match.total_turns} turns
              </span>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  def render(%{match: _} = assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app flash={@flash} players={@players} active_player_id={@active_player_id}>
      <.back_link navigate={~p"/matches"} label="All matches" />

      <h1 class="text-2xl font-semibold">{@match.event_name}</h1>
      <p class="text-sm text-base-content/60">
        {format_label(@match.format)} · {format_datetime(@match.started_at)}
      </p>

      <section :if={@match.games != []}>
        <h2 class="text-lg font-semibold mb-2">Games</h2>
        <table class="table table-sm">
          <thead>
            <tr>
              <th>#</th>
              <th>On play</th>
              <th>Turns</th>
              <th>Mulligans</th>
              <th>Colors</th>
              <th>Result</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={game <- @match.games}>
              <td>{game.game_number}</td>
              <td>{if game.on_play, do: "Yes", else: "No"}</td>
              <td class="tabular-nums">{game.num_turns || "—"}</td>
              <td class="tabular-nums">{game.num_mulligans || "—"}</td>
              <td>{game.main_colors || "—"}</td>
              <td><.result_badge won={game.won} /></td>
            </tr>
          </tbody>
        </table>
      </section>
    </Layouts.app>
    """
  end
end
