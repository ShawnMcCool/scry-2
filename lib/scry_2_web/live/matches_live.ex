defmodule Scry2Web.MatchesLive do
  use Scry2Web, :live_view

  alias Scry2.Matches
  alias Scry2.Topics

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
     assign(socket, matches: Matches.list_matches(limit: 100, player_id: player_id), match: nil)}
  end

  @impl true
  def handle_info({:match_updated, _}, socket) do
    {:noreply, schedule_reload(socket)}
  end

  def handle_info(:reload_data, socket) do
    player_id = socket.assigns[:active_player_id]

    {:noreply,
     assign(socket,
       matches: Matches.list_matches(limit: 100, player_id: player_id),
       reload_timer: nil
     )}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(%{match: nil} = assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app flash={@flash} players={@players} active_player_id={@active_player_id}>
      <h1 class="text-2xl font-semibold">Matches</h1>

      <.empty_state :if={@matches == []}>
        No matches recorded yet. Play a game with MTGA detailed logs enabled to see entries here.
      </.empty_state>

      <div :if={@matches != []} class="overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>Started</th>
              <th>Event</th>
              <th>Format</th>
              <th>Opponent</th>
              <th>Games</th>
              <th>Result</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={match <- @matches} class="hover">
              <td>
                <.link navigate={~p"/matches/#{match.id}"} class="link">
                  {format_datetime(match.started_at)}
                </.link>
              </td>
              <td>{match.event_name}</td>
              <td>{format_label(match.format)}</td>
              <td>{match.opponent_screen_name || "—"}</td>
              <td class="tabular-nums">{match.num_games || "—"}</td>
              <td><.result_badge won={match.won} /></td>
            </tr>
          </tbody>
        </table>
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
