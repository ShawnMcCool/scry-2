defmodule Scry2.Events.DieRollCompleted do
  @moduledoc """
  Domain event — dice were rolled at the start of a game to determine
  who goes first. The higher roll wins and chooses to play or draw
  (virtually always chooses play).

  ## Slug

  `"die_roll_completed"` — stable, do not rename.

  ## Source

  Produced from `GreToClientEvent` containing a
  `GREMessageType_DieRollResultsResp` message in the same batch as the
  ConnectResp (game start). Each game in a match gets a die roll.
  """

  @enforce_keys [:mtga_match_id, :self_roll, :opponent_roll, :self_goes_first, :occurred_at]
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

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "die_roll_completed"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
