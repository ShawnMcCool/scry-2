defmodule Scry2.Events.Economy.CollectionUpdated do
  @moduledoc """
  Domain event — full card collection snapshot. Carries a map of
  `arena_id => count` for every card the player owns.

  ## Slug

  `"collection_updated"` — stable, do not rename.

  ## Source

  Produced from `PlayerInventory.GetPlayerCardsV3` response events.
  These are large payloads (thousands of entries). The event stores the
  full map — aggregation and summarization belong in projections.
  """

  @enforce_keys [:card_counts, :occurred_at]
  defstruct [
    :player_id,
    :card_counts,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          card_counts: %{integer() => non_neg_integer()},
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "collection_updated"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
