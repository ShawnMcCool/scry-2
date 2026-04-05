defmodule Scry2Web.CardsLive do
  use Scry2Web, :live_view

  alias Scry2.Cards
  alias Scry2.Topics
  alias Scry2Web.CardsHelpers, as: Helpers

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Topics.subscribe(Topics.cards_updates())

    {:ok,
     socket
     |> assign(:cards, [])
     |> assign(:filters, %{name_like: "", rarity: nil, set_code: nil})
     |> assign(:total, 0)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = Helpers.coerce_filters(params)
    cards = Cards.list_cards(Map.put(filters, :limit, 200))

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:cards, cards)
     |> assign(:total, Cards.count())}
  end

  @impl true
  def handle_event("filter", %{"filters" => filter_params}, socket) do
    query = Helpers.filter_params_to_query(filter_params)
    {:noreply, push_patch(socket, to: ~p"/cards?#{query}")}
  end

  @impl true
  def handle_info({:cards_refreshed, _}, socket) do
    cards = Cards.list_cards(Map.put(socket.assigns.filters, :limit, 200))
    {:noreply, assign(socket, cards: cards, total: Cards.count())}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app flash={@flash}>
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-semibold">Cards</h1>
        <span class="text-sm text-base-content/60">{@total} total</span>
      </div>

      <form phx-change="filter" class="flex flex-wrap gap-3">
        <input
          type="text"
          name="filters[name_like]"
          placeholder="Search by name"
          class="input input-bordered input-sm"
          value={@filters.name_like || ""}
        />
        <select name="filters[rarity]" class="select select-bordered select-sm">
          <option value="">Any rarity</option>
          <option
            :for={r <- ~w(common uncommon rare mythic)}
            value={r}
            selected={@filters.rarity == r}
          >
            {String.capitalize(r)}
          </option>
        </select>
      </form>

      <div class="overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>Name</th>
              <th>Set</th>
              <th>Rarity</th>
              <th>MV</th>
              <th>Colors</th>
              <th>Arena ID</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={card <- @cards}>
              <td class="font-medium">{card.name}</td>
              <td>{Helpers.set_code(card)}</td>
              <td>
                <span class={"badge badge-sm #{Helpers.rarity_class(card.rarity)}"}>
                  {card.rarity}
                </span>
              </td>
              <td class="tabular-nums">{card.mana_value}</td>
              <td>{Helpers.color_identity_label(card.color_identity)}</td>
              <td class="tabular-nums text-base-content/60">{card.arena_id || "—"}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end
end
