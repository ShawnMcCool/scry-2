defmodule Scry2.Events.Economy.CardsAcquired do
  @moduledoc """
  Card counts increased in the player's collection.

  Event type: :state_change

  ## Source

  Emitted by `SnapshotConvert` from a changed `CollectionUpdated` snapshot.
  Contains only the cards whose count went up (new cards or additional copies).
  Also emitted on first collection observation to establish baseline.

  ## Fields

  - `player_id` — MTGA player identifier
  - `cards` — map of arena_id to count_increase (delta, not total)
  - `occurred_at` — when the acquisition was observed

  ## Slug

  `"cards_acquired"` — stable, do not rename.
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
          cards: %{integer() => non_neg_integer()},
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
    def type_slug(_), do: "cards_acquired"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
