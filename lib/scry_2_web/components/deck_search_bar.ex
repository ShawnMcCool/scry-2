defmodule Scry2Web.Components.DeckSearchBar do
  @moduledoc """
  The deck-catalog search bar: a name/archetype box, a card box, and the chip
  for the card once one is chosen. Renders `Scry2Web.DeckSearch` state and
  emits a fixed set of events the host LiveView wires straight back into that
  module — `search_name`, `pick_name`, `search_card`, `pick_card`,
  `clear_card`, `dismiss_suggestions`.

  The card box is replaced by its chip while a card is applied: one card at a
  time, and the chip is how you drop it.
  """
  use Phoenix.Component

  import Scry2Web.Components.SearchBox
  import Scry2Web.CoreComponents, only: [icon: 1]

  alias Scry2Web.DeckSearch

  attr :id, :string, required: true, doc: "prefix for the two inputs' DOM ids"
  attr :search, DeckSearch, required: true
  attr :name_placeholder, :string, required: true
  attr :card_placeholder, :string, default: "Filter by card…"
  attr :class, :string, default: nil

  def deck_search_bar(assigns) do
    ~H"""
    <div class={["flex flex-wrap items-start gap-3", @class]}>
      <.search_box
        id={@id <> "-name"}
        value={@search.query}
        placeholder={@name_placeholder}
        suggestions={@search.name_suggestions}
        input_event="search_name"
        pick_event="pick_name"
        dismiss_event="dismiss_suggestions"
      />
      <.search_box
        :if={is_nil(@search.card)}
        id={@id <> "-card"}
        value={@search.card_query}
        placeholder={@card_placeholder}
        suggestions={@search.card_suggestions}
        input_event="search_card"
        pick_event="pick_card"
        dismiss_event="dismiss_suggestions"
      />
      <div :if={@search.card} id={@id <> "-card-chip"} class="badge badge-outline badge-lg gap-2">
        <span>{@search.card.label}</span>
        <button type="button" phx-click="clear_card" aria-label="Clear card filter">
          <.icon name="hero-x-mark" class="size-3" />
        </button>
      </div>
    </div>
    """
  end
end
