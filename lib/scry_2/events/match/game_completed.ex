defmodule Scry2.Events.Match.GameCompleted do
  @moduledoc """
  An individual game within a match ended. A best-of-three match produces
  2–3 `GameCompleted` events plus one `MatchCompleted`.

  Event type: :state_change

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a `GreToClientEvent`
  containing a `GREMessageType_GameStateMessage` with
  `matchState: "MatchState_GameComplete"`. Fires when the game engine
  signals that the current game is over (win, loss, or draw).

  ## Fields

  - `player_id` — MTGA player identifier
  - `mtga_match_id` — match this game belongs to
  - `game_number` — which game within the match (1, 2, or 3)
  - `on_play` — true if the player was on the play (went first) for this game
  - `won` — true if the player won this individual game
  - `num_mulligans` — number of mulligans the player took this game
  - `opponent_num_mulligans` — number of mulligans the opponent took
  - `num_turns` — total number of turns in this game
  - `self_life_total` — player's life total when the game ended
  - `opponent_life_total` — opponent's life total when the game ended
  - `win_reason` — raw MTGA win reason string (e.g. `"ResultReason_LifeLoss"`)
  - `super_format` — format category (e.g. `"Constructed"`, `"Limited"`)

  ## Slug

  `"game_completed"` — stable, do not rename.
  """

  @enforce_keys [:mtga_match_id, :game_number, :occurred_at]
  defstruct [
    :player_id,
    :mtga_match_id,
    :game_number,
    :on_play,
    :won,
    :num_mulligans,
    :opponent_num_mulligans,
    :num_turns,
    :self_life_total,
    :opponent_life_total,
    :win_reason,
    :super_format,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          mtga_match_id: String.t(),
          game_number: pos_integer(),
          on_play: boolean() | nil,
          won: boolean() | nil,
          num_mulligans: non_neg_integer() | nil,
          opponent_num_mulligans: non_neg_integer() | nil,
          num_turns: non_neg_integer() | nil,
          self_life_total: integer() | nil,
          opponent_life_total: integer() | nil,
          win_reason: String.t() | nil,
          super_format: String.t() | nil,
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "game_completed"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
