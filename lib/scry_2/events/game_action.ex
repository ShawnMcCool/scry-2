defmodule Scry2.Events.GameAction do
  @moduledoc """
  Domain event — a discrete player action during a game.

  ## Slug

  `"game_action"` — stable, do not rename.

  ## Source

  Produced from `ClientToGremessage` raw events, which carry the
  player's in-game decisions. Only a subset of GRE message types are
  translated — high-signal decisions, not UI noise.

  ## Action types

  - `"concede"` — player conceded the game
  - `"mulligan_decision"` — explicit keep/mulligan response
    (`decision`: `"keep"` or `"mulligan"`)
  - `"choose_starting_player"` — play/draw choice after winning the die roll
    (`chose_play`: boolean)
  """

  @enforce_keys [:action, :occurred_at]
  defstruct [
    :player_id,
    :mtga_match_id,
    :action,
    :decision,
    :chose_play,
    :scope,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: integer() | nil,
          mtga_match_id: String.t() | nil,
          action: String.t(),
          decision: String.t() | nil,
          chose_play: boolean() | nil,
          scope: String.t() | nil,
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "game_action"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
