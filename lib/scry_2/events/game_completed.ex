defmodule Scry2.Events.GameCompleted do
  @moduledoc """
  Domain event — an individual game within a match ended. A best-of-three
  match produces 2–3 `%GameCompleted{}` events plus one `%MatchCompleted{}`.

  ## Slug

  `"game_completed"` — stable, do not rename.

  ## Source (future)

  Will be produced by `Scry2.Events.IdentifyDomainEvents` from `GreToClientEvent`
  messages containing a `GREMessageType_GameStateMessage` with
  `matchState: "MatchState_GameComplete"`. See ADR-018 and
  `TODO.md` > "Match ingestion follow-ups" > per-game results.

  ## Projected by (future)

  `Scry2.Matches.UpdateFromEvent` will project to `matches_games` via
  `Scry2.Matches.upsert_game!/1`, keyed on `(match_id, game_number)`.

  ## Status

  Struct defined; no translator clause or projector handler wired yet.
  The struct exists to document the vocabulary and reserve the slug.
  """

  @enforce_keys [:mtga_match_id, :game_number, :occurred_at]
  defstruct [
    :player_id,
    :mtga_match_id,
    :game_number,
    :on_play,
    :won,
    :num_mulligans,
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
