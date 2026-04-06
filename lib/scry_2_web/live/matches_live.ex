defmodule Scry2Web.MatchesLive do
  use Scry2Web, :live_view

  alias Scry2.MatchListing
  alias Scry2.Topics
  alias Scry2Web.MatchesHelpers, as: Helpers

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Topics.subscribe(Topics.matches_updates())

    {:ok, assign(socket, matches: [], match: nil)}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    match = MatchListing.get_match_with_associations(String.to_integer(id))
    {:noreply, assign(socket, match: match, matches: [])}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, matches: MatchListing.list_matches(limit: 100), match: nil)}
  end

  @impl true
  def handle_info({:match_updated, _}, socket) do
    {:noreply, assign(socket, :matches, MatchListing.list_matches(limit: 100))}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(%{match: nil} = assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app flash={@flash}>
      <h1 class="text-2xl font-semibold">Matches</h1>

      <p :if={@matches == []} class="text-base-content/60">
        No matches recorded yet. Play a game with MTGA detailed logs enabled to see entries here.
      </p>

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
                  {Helpers.format_started_at(match.started_at)}
                </.link>
              </td>
              <td>{match.event_name}</td>
              <td>{Helpers.format_label(match.format)}</td>
              <td>{match.opponent_screen_name || "—"}</td>
              <td class="tabular-nums">{match.num_games || "—"}</td>
              <td>
                <span class={"badge badge-sm #{Helpers.result_class(match.won)}"}>
                  {Helpers.result_label(match.won)}
                </span>
              </td>
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
    <Layouts.app flash={@flash}>
      <.link navigate={~p"/matches"} class="link text-sm">&larr; All matches</.link>

      <h1 class="text-2xl font-semibold">{@match.event_name}</h1>
      <p class="text-sm text-base-content/60">
        {Helpers.format_label(@match.format)} · {Helpers.format_started_at(@match.started_at)}
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
              <td>
                <span class={"badge badge-sm #{Helpers.result_class(game.won)}"}>
                  {Helpers.result_label(game.won)}
                </span>
              </td>
            </tr>
          </tbody>
        </table>
      </section>
    </Layouts.app>
    """
  end
end
