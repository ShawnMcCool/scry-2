defmodule Scry2.Events.DeckSelected do
  @moduledoc """
  Domain event — the player selected a deck for an MTGA event.
  Captures the full deck list at the time of selection.

  ## Slug

  `"deck_selected"` — stable, do not rename.

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a raw
  `EventSetDeckV2` request. The request carries the full deck list
  including main deck and sideboard.
  """

  @enforce_keys [:event_name, :main_deck, :occurred_at]
  defstruct [
    :player_id,
    :event_name,
    :deck_id,
    :deck_name,
    :main_deck,
    :sideboard,
    :occurred_at
  ]

  @type card_entry :: %{arena_id: integer(), count: pos_integer()}

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          event_name: String.t(),
          deck_id: String.t() | nil,
          deck_name: String.t() | nil,
          main_deck: [card_entry()],
          sideboard: [card_entry()] | nil,
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "deck_selected"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
