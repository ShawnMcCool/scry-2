defmodule Scry2.Events.Economy.CardsRemoved do
  @moduledoc """
  Card counts decreased in the player's collection.

  Event type: :state_change

  ## Source

  Emitted by `SnapshotConvert` from a changed `CollectionUpdated` snapshot.
  Contains only the cards whose count went down (used or traded away). Emitted
  alongside `CardsAcquired` when needed.

  ## Fields

  - `player_id` — MTGA player identifier
  - `cards` — map of arena_id to count_decrease (delta, not total)
  - `occurred_at` — when the removal was observed

  ## Slug

  `"cards_removed"` — stable, do not rename.
  """

  @enforce_keys [:cards, :occurred_at]
  @behaviour Scry2.Events.DomainEvent

  alias Scry2.Events.Payload

  defstruct [
    :player_id,
    :cards,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          cards: %{integer() => pos_integer()},
          occurred_at: DateTime.t()
        }

  def from_payload(payload) do
    %__MODULE__{
      player_id: payload["player_id"],
      cards: Payload.integer_keys(payload["cards"] || %{}),
      occurred_at: Payload.parse_datetime(payload["occurred_at"])
    }
  end

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "cards_removed"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
