defmodule Scry2.Events.Deck.DeckSelected do
  @moduledoc """
  The player selected a deck for an MTGA event. Captures the full deck list at
  the time of selection.

  Event type: :state_change

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a raw `EventSetDeckV2`
  request. Fires when the player chooses a deck before entering a match queue.
  The request carries the full deck list including main deck and sideboard.

  ## Fields

  - `player_id` — MTGA player identifier
  - `event_name` — internal MTGA event identifier (e.g. `"Play_Ranked"`)
  - `deck_id` — MTGA deck identifier (may be nil for sealed pools)
  - `deck_name` — player-assigned deck name
  - `main_deck` — list of `%{arena_id, count}` entries for the main deck
  - `sideboard` — list of `%{arena_id, count}` entries for the sideboard, or nil

  ## Slug

  `"deck_selected"` — stable, do not rename.
  """

  @enforce_keys [:event_name, :main_deck, :occurred_at]
  @behaviour Scry2.Events.DomainEvent

  alias Scry2.Events.Payload

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

  def from_payload(payload) do
    %__MODULE__{
      player_id: payload["player_id"],
      event_name: payload["event_name"],
      deck_id: payload["deck_id"],
      deck_name: payload["deck_name"],
      main_deck: payload["main_deck"] || [],
      sideboard: payload["sideboard"] || [],
      occurred_at: Payload.parse_datetime(payload["occurred_at"])
    }
  end

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "deck_selected"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
