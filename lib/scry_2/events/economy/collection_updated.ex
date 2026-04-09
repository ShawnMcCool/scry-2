defmodule Scry2.Events.Economy.CollectionUpdated do
  @moduledoc """
  Full card collection snapshot: a map of every card the player owns
  with their copy counts.

  Event type: :snapshot

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a raw
  `PlayerInventory.GetPlayerCardsV3` response. Fires on login and during
  periodic collection sync. These are large payloads (thousands of entries).
  The event stores the full map — aggregation belongs in projections.

  ## Fields

  - `player_id` — MTGA player identifier
  - `card_counts` — map of `arena_id => copy_count` for every owned card

  ## Diff key

  `SnapshotDiff` compares the `card_counts` map directly. Any change in any
  card's copy count — whether from drafting, opening packs, crafting, or
  trading — triggers a new event.

  ## Slug

  `"collection_updated"` — stable, do not rename.
  """

  @enforce_keys [:card_counts, :occurred_at]
  @behaviour Scry2.Events.DomainEvent

  alias Scry2.Events.Payload

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

  def from_payload(payload) do
    %__MODULE__{
      player_id: payload["player_id"],
      card_counts: Payload.integer_keys(payload["card_counts"] || %{}),
      occurred_at: Payload.parse_datetime(payload["occurred_at"])
    }
  end

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "collection_updated"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
