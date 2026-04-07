defmodule Scry2Web.MulligansLive do
  @moduledoc """
  LiveView for browsing mulligan decisions — every opening hand seen
  and whether it was kept or mulliganed.
  """
  use Scry2Web, :live_view

  alias Scry2.Events
  alias Scry2.Topics
  alias Scry2Web.MulligansHelpers

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Topics.subscribe(Topics.domain_events())

    {:ok, assign(socket, matches: [], reload_timer: nil)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    player_id = socket.assigns[:active_player_id]
    matches = load_mulligans(player_id)
    {:noreply, assign(socket, matches: matches)}
  end

  @impl true
  def handle_info({:domain_event, _id, "mulligan_offered"}, socket) do
    {:noreply, schedule_reload(socket)}
  end

  def handle_info({:domain_event, _id, _type}, socket), do: {:noreply, socket}

  def handle_info(:reload_data, socket) do
    player_id = socket.assigns[:active_player_id]
    {:noreply, assign(socket, matches: load_mulligans(player_id), reload_timer: nil)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app flash={@flash} players={@players} active_player_id={@active_player_id}>
      <h1 class="text-2xl font-semibold mb-4">Mulligans</h1>

      <.empty_state :if={@matches == []}>
        No mulligan data recorded yet. Play a game with MTGA detailed logs enabled.
      </.empty_state>

      <div :for={match <- @matches} class="mb-8">
        <div class="flex items-center gap-2 mb-3">
          <h2 class="text-sm font-semibold text-base-content/50 uppercase tracking-wider">
            Match
          </h2>
          <.link
            :if={match.match_id}
            navigate={~p"/events?match_id=#{match.match_id}"}
            class="font-mono text-xs text-accent/70 hover:text-accent"
          >
            {truncate_id(match.match_id)}
          </.link>
        </div>

        <div class="flex flex-col gap-2">
          <div
            :for={{offer, decision} <- match.hands}
            class={[
              "flex items-center gap-4 px-4 py-3 rounded-lg",
              "bg-base-200/50 border-l-[3px]",
              MulligansHelpers.decision_border_class(decision)
            ]}
          >
            <div class="min-w-[80px]">
              <span class={["badge badge-sm", MulligansHelpers.decision_badge_class(decision)]}>
                {MulligansHelpers.decision_label(decision)}
              </span>
            </div>

            <div :if={offer.hand_arena_ids} class="flex-1">
              <.card_hand arena_ids={offer.hand_arena_ids} class="w-12" />
            </div>
            <span :if={!offer.hand_arena_ids} class="flex-1 text-base-content/30">
              —
            </span>

            <span class="text-xs text-base-content/40 tabular-nums whitespace-nowrap">
              {offer.hand_size} cards
            </span>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp load_mulligans(player_id) do
    matches =
      Events.list_mulligans(player_id: player_id)
      |> MulligansHelpers.group_by_match()

    arena_ids =
      matches
      |> Enum.flat_map(fn %{hands: hands} ->
        Enum.flat_map(hands, fn {offer, _decision} ->
          offer.hand_arena_ids || []
        end)
      end)
      |> Enum.uniq()

    if arena_ids != [], do: Scry2.Cards.ImageCache.ensure_cached(arena_ids)

    matches
  end

  defp truncate_id(id) when is_binary(id) and byte_size(id) > 12 do
    String.slice(id, 0, 12) <> "…"
  end

  defp truncate_id(id), do: id
end
