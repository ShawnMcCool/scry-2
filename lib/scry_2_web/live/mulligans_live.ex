defmodule Scry2Web.MulligansLive do
  @moduledoc """
  LiveView for browsing mulligan decisions — every opening hand seen
  and whether it was kept or mulliganed.

  Data comes from the `mulligans_mulligan_listing` projection table
  (ADR-026), not from the raw domain event log.
  """
  use Scry2Web, :live_view

  alias Scry2.Mulligans
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
    hands = Mulligans.list_hands(player_id: player_id)
    events = MulligansHelpers.group_for_display(hands)

    arena_ids =
      hands
      |> Enum.flat_map(fn hand ->
        (hand.hand_arena_ids && hand.hand_arena_ids["cards"]) || []
      end)
      |> Enum.uniq()

    socket = assign(socket, events: events)

    socket =
      if arena_ids != [],
        do:
          start_async(socket, :cache_images, fn ->
            Scry2.Cards.ImageCache.ensure_cached(arena_ids)
          end),
        else: socket

    {:noreply, socket}
  end

  @impl true
  def handle_info({:domain_event, _id, "mulligan_offered"}, socket) do
    {:noreply, schedule_reload(socket)}
  end

  def handle_info({:domain_event, _id, _type}, socket), do: {:noreply, socket}

  def handle_info(:reload_data, socket) do
    player_id = socket.assigns[:active_player_id]
    hands = Mulligans.list_hands(player_id: player_id)
    events = MulligansHelpers.group_for_display(hands)
    {:noreply, assign(socket, events: events, reload_timer: nil)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:cache_images, {:ok, _stats}, socket), do: {:noreply, socket}
  def handle_async(:cache_images, {:exit, _reason}, socket), do: {:noreply, socket}

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
                  :for={{hand, decision} <- game.hands}
                  class={["flex flex-col items-center", decision == :mulliganed && "opacity-80"]}
                >
                  <div :if={hand.arena_ids != []} class="mb-3">
                    <.card_hand arena_ids={hand.arena_ids} class="w-[10rem]" />
                  </div>
                  <span :if={hand.arena_ids == []} class="text-base-content/20 mb-3">
                    Hand data not available in MTGA log
                  </span>

                  <div
                    :if={hand.land_count}
                    class="flex items-center gap-4 mb-3 text-xs text-base-content/40"
                  >
                    <span>
                      {hand.land_count} lands · {hand.nonland_count} spells
                    </span>
                    <span :if={hand.total_cmc && hand.total_cmc > 0}>
                      avg
                      <span class="text-base-content/60 tabular-nums">
                        {Float.round(hand.total_cmc / max(hand.nonland_count || 1, 1), 1)}
                      </span>
                      cmc
                    </span>
                    <span
                      :for={{color, count} <- hand.color_distribution}
                      class="flex items-center gap-0.5"
                    >
                      <.mana_pip color={color} />
                      <span class="text-base-content/25">×{count}</span>
                    </span>
                  </div>

                  <div class="flex gap-8">
                    <span class={[
                      "px-6 py-2 rounded-xl text-base font-bold tracking-wide",
                      if(decision == :mulliganed,
                        do: "bg-blue-500/90 text-white",
                        else: "bg-base-content/10 text-base-content/25"
                      )
                    ]}>
                      Mulligan
                    </span>
                    <span class={[
                      "px-6 py-2 rounded-xl text-base font-bold tracking-wide",
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

  defp format_game_time(%{hands: [{first, _} | _]}) do
    first.occurred_at
    |> Calendar.strftime("%b %d, %Y · %H:%M")
  end

  defp format_game_time(_), do: ""
end
