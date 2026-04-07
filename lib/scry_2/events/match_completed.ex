defmodule Scry2.Events.MatchCompleted do
  @moduledoc """
  Domain event — an MTGA match ended, with a final result. Pairs with
  a preceding `%Scry2.Events.MatchCreated{}` sharing the same
  `mtga_match_id`.

  ## Slug

  `"match_completed"` — stable, do not rename.

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a raw
  `MatchGameRoomStateChangedEvent` with `stateType: "MatchGameRoomStateType_MatchCompleted"`.
  The translator computes `won` by comparing the `winningTeamId` from
  `finalMatchResult.resultList[]` (the `MatchScope_Match` row) to the
  self team id derived from `reservedPlayers[]`.

  ## Projected by

  `Scry2.Matches.UpdateFromEvent` — enriches the existing `matches_matches`
  row (keyed on `mtga_match_id`) via `Scry2.Matches.upsert_match!/1`.
  Idempotent — replaying produces the same row state.

  ## Fields

  Self-contained — projectors never need to look up the `MatchCreated`
  row to derive a field. The translator computes `won` at event-build
  time using `self_user_id` config and the raw `reservedPlayers[]`.
  """

  @enforce_keys [:mtga_match_id, :occurred_at, :won, :num_games]
  defstruct [
    :player_id,
    :mtga_match_id,
    :occurred_at,
    :won,
    :num_games,
    :reason,
    :game_results
  ]

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          mtga_match_id: String.t(),
          occurred_at: DateTime.t(),
          won: boolean(),
          num_games: non_neg_integer(),
          reason: String.t() | nil,
          game_results:
            [%{game_number: pos_integer(), winning_team_id: integer(), reason: String.t()}] | nil
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "match_completed"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
