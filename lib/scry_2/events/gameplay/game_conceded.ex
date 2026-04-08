defmodule Scry2.Events.Gameplay.GameConceded do
  @moduledoc """
  Domain event — a player conceded the current game.

  ## Slug

  `"game_conceded"` — stable, do not rename.

  ## Source

  Produced from `ClientToGremessage` raw events with type
  `ClientMessageType_ConcedeReq`.
  """

  @enforce_keys [:occurred_at]
  defstruct [:player_id, :mtga_match_id, :scope, :occurred_at]

  @type t :: %__MODULE__{
          player_id: integer() | nil,
          mtga_match_id: String.t() | nil,
          scope: String.t() | nil,
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "game_conceded"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
