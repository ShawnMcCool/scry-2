defmodule Scry2.Events.Deck.DeckUpdated do
  @moduledoc """
  The player created, edited, or cloned a deck. Captures the full deck list
  at the time of the change.

  Event type: :state_change

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a raw `DeckUpsertDeckV2`
  request. Fires when the player saves any deck change in the collection screen.
  The `action_type` field indicates what kind of change was made (e.g.
  `"Cloned"`, `"Update"`).

  ## Fields

  - `player_id` — MTGA player identifier
  - `deck_id` — MTGA deck identifier for the affected deck
  - `deck_name` — player-assigned deck name after the change
  - `format` — deck format (e.g. `"Standard"`, `"Historic"`)
  - `action_type` — kind of change: `"Cloned"`, `"Update"`, etc.
  - `main_deck` — list of `%{arena_id, count}` entries for the main deck
  - `sideboard` — list of `%{arena_id, count}` entries for the sideboard, or nil

  ## Slug

  `"deck_updated"` — stable, do not rename.
  """

  @enforce_keys [:deck_id, :main_deck, :occurred_at]
  @behaviour Scry2.Events.DomainEvent

  alias Scry2.Events.Payload

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

  def from_payload(payload) do
    %__MODULE__{
      player_id: payload["player_id"],
      deck_id: payload["deck_id"],
      deck_name: payload["deck_name"],
      format: payload["format"],
      action_type: payload["action_type"],
      main_deck: payload["main_deck"] || [],
      sideboard: payload["sideboard"] || [],
      occurred_at: Payload.parse_datetime(payload["occurred_at"])
    }
  end

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "deck_updated"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
