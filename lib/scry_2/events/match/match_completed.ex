defmodule Scry2.Events.Match.MatchCompleted do
  @moduledoc """
  An MTGA match ended with a final result. Pairs with a preceding `MatchCreated`
  sharing the same `mtga_match_id`.

  Event type: :state_change

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a raw
  `MatchGameRoomStateChangedEvent` with `stateType: "MatchGameRoomStateType_MatchCompleted"`.
  Fires when the match game room transitions to the completed state.
  The translator computes `won` by comparing the `winningTeamId` from
  `finalMatchResult.resultList[]` (the `MatchScope_Match` row) to the self
  team id derived from `reservedPlayers[]`.

  ## Fields

  Self-contained — projectors never need to look up the `MatchCreated` row
  to derive a field. The translator computes `won` at event-build time.

  - `player_id` — MTGA player identifier
  - `mtga_match_id` — stable match identifier linking to `MatchCreated`
  - `won` — true if the player won the match
  - `num_games` — total number of games played in the match
  - `reason` — overall match result reason (e.g. `"ResultReason_LifeLoss"`)
  - `game_results` — per-game list of `%{game_number, winning_team_id, reason}`

  ## Slug

  `"match_completed"` — stable, do not rename.
  """

  @enforce_keys [:mtga_match_id, :occurred_at, :won, :num_games]
  @behaviour Scry2.Events.DomainEvent

  alias Scry2.Events.Payload

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

  def from_payload(payload) do
    %__MODULE__{
      player_id: payload["player_id"],
      mtga_match_id: payload["mtga_match_id"],
      won: payload["won"],
      num_games: payload["num_games"],
      reason: payload["reason"],
      game_results: payload["game_results"],
      occurred_at: Payload.parse_datetime(payload["occurred_at"])
    }
  end

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "match_completed"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
