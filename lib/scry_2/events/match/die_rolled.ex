defmodule Scry2.Events.Match.DieRolled do
  @moduledoc """
  Dice were rolled at the start of a game to determine who goes first. The
  higher roll wins and chooses to play or draw.

  Event type: :state_change

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a `GreToClientEvent`
  containing a `GREMessageType_DieRollResultsResp` message. Fires in the same
  GRE batch as the `ConnectResp` at game start. Each game in a match gets its
  own die roll.

  ## Fields

  - `player_id` — MTGA player identifier
  - `mtga_match_id` — match this die roll belongs to
  - `self_roll` — the player's die roll result
  - `opponent_roll` — the opponent's die roll result
  - `self_goes_first` — true if the player won the die roll and goes first

  ## Slug

  `"die_roll_completed"` — stable, do not rename.
  """

  @enforce_keys [:mtga_match_id, :self_roll, :opponent_roll, :self_goes_first, :occurred_at]
  @behaviour Scry2.Events.DomainEvent

  alias Scry2.Events.Payload

  defstruct [
    :player_id,
    :mtga_match_id,
    :self_roll,
    :opponent_roll,
    :self_goes_first,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          mtga_match_id: String.t(),
          self_roll: integer(),
          opponent_roll: integer(),
          self_goes_first: boolean(),
          occurred_at: DateTime.t()
        }

  def from_payload(payload) do
    %__MODULE__{
      player_id: payload["player_id"],
      mtga_match_id: payload["mtga_match_id"],
      self_roll: payload["self_roll"],
      opponent_roll: payload["opponent_roll"],
      self_goes_first: payload["self_goes_first"],
      occurred_at: Payload.parse_datetime(payload["occurred_at"])
    }
  end

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "die_roll_completed"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
