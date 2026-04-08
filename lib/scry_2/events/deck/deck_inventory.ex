defmodule Scry2.Events.Deck.DeckInventory do
  @moduledoc """
  Domain event — snapshot of the player's deck collection (names,
  IDs, formats, last-updated timestamps).

  ## Slug

  `"deck_inventory"` — stable, do not rename.

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a raw
  `DeckGetDeckSummariesV2` response.
  """

  @enforce_keys [:decks, :occurred_at]
  defstruct [
    :player_id,
    :decks,
    :occurred_at
  ]

  @type deck_summary :: %{
          deck_id: String.t(),
          name: String.t() | nil,
          format: String.t() | nil
        }

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          decks: [deck_summary()],
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "deck_inventory"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
