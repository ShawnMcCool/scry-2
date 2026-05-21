defmodule Scry2.Events.Deck.DeckDeleted do
  @moduledoc """
  The player deleted a constructed deck in MTGA's collection screen.

  Event type: :state_change

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a raw `DeckDeleteDeck`
  request. The deck row in `decks_decks` is preserved — this event only
  flips the `archived` flag so the deck is hidden from the default decks
  view but remains exportable for re-import.

  ## Fields

  - `player_id` — MTGA player identifier (set by `Scry2.Events.append!/3`
    when the event is persisted)
  - `mtga_deck_id` — MTGA deck identifier (from the request payload's `DeckId`)
  - `occurred_at` — when the deletion was logged (raw event `mtga_timestamp`
    or `inserted_at` fallback)

  ## Slug

  `"deck_deleted"` — stable, do not rename.
  """

  @enforce_keys [:mtga_deck_id, :occurred_at]
  @behaviour Scry2.Events.DomainEvent

  alias Scry2.Events.Payload

  defstruct [:player_id, :mtga_deck_id, :occurred_at]

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          mtga_deck_id: String.t(),
          occurred_at: DateTime.t() | nil
        }

  def from_payload(payload) do
    %__MODULE__{
      player_id: payload["player_id"],
      mtga_deck_id: payload["mtga_deck_id"],
      occurred_at: Payload.parse_datetime(payload["occurred_at"])
    }
  end

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "deck_deleted"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
