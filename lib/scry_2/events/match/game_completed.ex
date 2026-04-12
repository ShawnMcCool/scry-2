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

  ## GRE concession bug — `won` is unreliable

  The `won` field comes from the GRE's `GameStateMessage`, which reports the
  last game state before a concession — NOT the actual outcome. When a player
  concedes while ahead on board, the GRE incorrectly reports the conceding
  player as "winning" that game. The authoritative per-game win/loss source
  is `MatchCompleted.game_results` from the matchmaking layer.

  **Projections that store per-game `won` must correct on `MatchCompleted`.**
  Both `MatchProjection` and `DeckProjection` implement this correction.
  See `MatchCompleted` @moduledoc and "GRE game results" in
  `IdentifyDomainEvents` @moduledoc for the full protocol explanation.

  ## Slug

  `"game_completed"` — stable, do not rename.
  """

  @enforce_keys [:mtga_match_id, :game_number, :occurred_at]
  @behaviour Scry2.Events.DomainEvent

  alias Scry2.Events.Payload

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

  def from_payload(payload) do
    %__MODULE__{
      player_id: payload["player_id"],
      mtga_match_id: payload["mtga_match_id"],
      game_number: payload["game_number"],
      on_play: payload["on_play"],
      won: payload["won"],
      num_mulligans: payload["num_mulligans"],
      opponent_num_mulligans: payload["opponent_num_mulligans"],
      num_turns: payload["num_turns"],
      self_life_total: payload["self_life_total"],
      opponent_life_total: payload["opponent_life_total"],
      win_reason: payload["win_reason"],
      super_format: payload["super_format"],
      occurred_at: Payload.parse_datetime(payload["occurred_at"])
    }
  end

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "game_completed"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
