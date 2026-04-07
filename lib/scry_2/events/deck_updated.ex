defmodule Scry2.Events.DeckUpdated do
  @moduledoc """
  Domain event — the player created, edited, or cloned a deck.
  Captures the full deck list at the time of the change.

  ## Slug

  `"deck_updated"` — stable, do not rename.

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a raw
  `DeckUpsertDeckV2` request. The `action_type` field indicates
  what kind of change was made (e.g. "Cloned", "Update").
  """

  @enforce_keys [:deck_id, :main_deck, :occurred_at]
  defstruct [
    :player_id,
    :deck_id,
    :deck_name,
    :format,
    :action_type,
    :main_deck,
    :sideboard,
    :occurred_at
  ]

  @type card_entry :: %{arena_id: integer(), count: pos_integer()}

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          deck_id: String.t(),
          deck_name: String.t() | nil,
          format: String.t() | nil,
          action_type: String.t() | nil,
          main_deck: [card_entry()],
          sideboard: [card_entry()] | nil,
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "deck_updated"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
