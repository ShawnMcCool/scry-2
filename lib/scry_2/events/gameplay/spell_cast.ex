defmodule Scry2.Events.Gameplay.SpellCast do
  @moduledoc """
  A spell was cast from hand to the stack.

  Event type: :state_change

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a `GreToClientEvent`
  containing an `AnnotationType_ZoneTransfer` annotation with category
  `CastSpell`. Fires when a non-land card moves from hand to the stack.

  ## Fields

  - `player_id` — MTGA player identifier
  - `mtga_match_id` — match the spell was cast in
  - `turn_number` — turn number when the spell was cast
  - `phase` — game phase when the spell was cast
  - `active_player` — seat ID of the player whose turn it is
  - `card_arena_id` — arena_id of the spell cast
  - `card_name` — resolved card name (enriched at ingestion)

  ## Slug

  `"spell_cast"` — stable, do not rename.
  """

  @behaviour Scry2.Events.DomainEvent

  alias Scry2.Events.Payload

  @enforce_keys [:occurred_at]
  defstruct [
    :player_id,
    :mtga_match_id,
    :turn_number,
    :phase,
    :active_player,
    :card_arena_id,
    :card_name,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: integer() | nil,
          mtga_match_id: String.t() | nil,
          turn_number: non_neg_integer() | nil,
          phase: String.t() | nil,
          active_player: integer() | nil,
          card_arena_id: integer() | nil,
          card_name: String.t() | nil,
          occurred_at: DateTime.t()
        }

  def from_payload(payload) do
    %__MODULE__{
      player_id: payload["player_id"],
      mtga_match_id: payload["mtga_match_id"],
      turn_number: payload["turn_number"],
      phase: payload["phase"],
      active_player: payload["active_player"],
      card_arena_id: payload["card_arena_id"],
      card_name: payload["card_name"],
      occurred_at: Payload.parse_datetime(payload["occurred_at"])
    }
  end

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "spell_cast"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
