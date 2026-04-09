defmodule Scry2.Events.Gameplay.LifeTotalChanged do
  @moduledoc """
  A player's life total changed during a game.

  Event type: :state_change

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a `GreToClientEvent`
  containing an `AnnotationType_LifeTotalChanged` annotation. Fires on any
  life total change — damage, life gain, or direct manipulation.

  ## Fields

  - `player_id` — MTGA player identifier
  - `mtga_match_id` — match the life change occurred in
  - `turn_number` — turn number when the life total changed
  - `phase` — game phase during which the change occurred
  - `active_player` — seat ID of the player whose turn it is
  - `amount` — magnitude of the life change (positive = gain, negative = loss)
  - `affected_player` — seat ID of the player whose life total changed

  ## Slug

  `"life_total_changed"` — stable, do not rename.
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
    :amount,
    :affected_player,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: integer() | nil,
          mtga_match_id: String.t() | nil,
          turn_number: non_neg_integer() | nil,
          phase: String.t() | nil,
          active_player: integer() | nil,
          amount: integer() | nil,
          affected_player: integer() | nil,
          occurred_at: DateTime.t()
        }

  def from_payload(payload) do
    %__MODULE__{
      player_id: payload["player_id"],
      mtga_match_id: payload["mtga_match_id"],
      turn_number: payload["turn_number"],
      phase: payload["phase"],
      active_player: payload["active_player"],
      amount: payload["amount"],
      affected_player: payload["affected_player"],
      occurred_at: Payload.parse_datetime(payload["occurred_at"])
    }
  end

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "life_total_changed"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
