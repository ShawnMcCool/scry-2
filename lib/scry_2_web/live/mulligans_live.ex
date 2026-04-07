defmodule Scry2Web.MulligansLive do
  @moduledoc """
  LiveView for browsing mulligan decisions — every opening hand seen
  and whether it was kept or mulliganed.
  """
  use Scry2Web, :live_view

  alias Scry2.Events
  alias Scry2.Matches
  alias Scry2.Topics
  alias Scry2Web.MulligansHelpers

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Topics.subscribe(Topics.domain_events())

    {:ok, assign(socket, events: [], reload_timer: nil)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    player_id = socket.assigns[:active_player_id]
    events = load_mulligans(player_id)
    {:noreply, assign(socket, events: events)}
  end

  @impl true
  def handle_info({:domain_event, _id, "mulligan_offered"}, socket) do
    {:noreply, schedule_reload(socket)}
  end

  def handle_info({:domain_event, _id, _type}, socket), do: {:noreply, socket}

  def handle_info(:reload_data, socket) do
    player_id = socket.assigns[:active_player_id]
    {:noreply, assign(socket, events: load_mulligans(player_id), reload_timer: nil)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app flash={@flash} players={@players} active_player_id={@active_player_id}>
      <h1 class="text-2xl font-semibold mb-6">Mulligans</h1>

      <.empty_state :if={@events == []}>
        No mulligan data recorded yet. Play a game with MTGA detailed logs enabled.
      </.empty_state>

      <div class="flex flex-col gap-16">
        <section :for={event <- @events}>
          <h2 class="text-sm font-semibold text-base-content/40 uppercase tracking-wider mb-6">
            {event.event_name}
          </h2>

          <div class="flex flex-col gap-12">
            <div :for={{game, game_index} <- Enum.with_index(event.games, 1)}>
              <div class="text-center mb-4">
                <span :if={length(event.games) > 1} class="text-xs text-base-content/25">
                  Game {game_index} ·
                </span>
                <span class="text-xs text-base-content/25 tabular-nums">
                  {format_game_time(game)}
                </span>
              </div>

              <div class="flex flex-col gap-8">
                <div
                  :for={{offer, decision} <- game.hands}
                  class={["flex flex-col items-center", decision == :mulliganed && "opacity-80"]}
                >
                  <div :if={offer.hand_arena_ids} class="mb-4">
                    <.card_hand arena_ids={offer.hand_arena_ids} class="w-[13.5rem]" />
                  </div>
                  <span :if={!offer.hand_arena_ids} class="text-base-content/20 mb-4">
                    Hand data not available in MTGA log
                  </span>

                  <div class="flex gap-8">
                    <span class={[
                      "px-8 py-2.5 rounded-xl text-lg font-bold tracking-wide",
                      if(decision == :mulliganed,
                        do: "bg-blue-500/90 text-white",
                        else: "bg-base-content/10 text-base-content/25"
                      )
                    ]}>
                      Mulligan
                    </span>
                    <span class={[
                      "px-8 py-2.5 rounded-xl text-lg font-bold tracking-wide",
                      if(decision == :kept,
                        do: "bg-orange-500/90 text-white",
                        else: "bg-base-content/10 text-base-content/25"
                      )
                    ]}>
                      Keep
                    </span>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <div class="border-t border-base-content/5 mt-10" />
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp load_mulligans(player_id) do
    matches =
      Events.list_mulligans(player_id: player_id)
      |> MulligansHelpers.group_by_match()

    # Build a lookup of match_id → Match for event name resolution.
    match_ids = Enum.map(matches, & &1.match_id) |> Enum.reject(&is_nil/1)

    match_lookup =
      match_ids
      |> Enum.reduce(%{}, fn match_id, acc ->
        case Matches.get_by_mtga_id(match_id) do
          nil -> acc
          match -> Map.put(acc, match_id, match)
        end
      end)

    events = MulligansHelpers.group_by_event(matches, match_lookup)

    # Pre-cache card images.
    arena_ids =
      matches
      |> Enum.flat_map(fn %{hands: hands} ->
        Enum.flat_map(hands, fn {offer, _decision} ->
          offer.hand_arena_ids || []
        end)
      end)
      |> Enum.uniq()

    if arena_ids != [], do: Scry2.Cards.ImageCache.ensure_cached(arena_ids)

    events
  end

  defp format_game_time(%{hands: [{first, _} | _]}) do
    first.occurred_at
    |> Calendar.strftime("%b %d, %Y · %H:%M")
  end

  defp format_game_time(_), do: ""
end
