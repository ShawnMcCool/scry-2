defmodule Scry2.Events.Combat.AttackersDeclared do
  @moduledoc """
  Attackers were declared for this combat step.

  ## Source

  Produced from `ClientToGremessage` (our attack) or from `GameStateMessage`
  annotations (opponent's attack — inferred from game state).

  ## Fields

  - `attackers` — list of `%{arena_id: integer, instance_id: integer}` maps

  ## Slug

  `"attackers_declared"` — stable, do not rename.
  """
  @behaviour Scry2.Events.DomainEvent
  alias Scry2.Events.Payload
  @enforce_keys [:occurred_at]
  defstruct [:player_id, :mtga_match_id, :game_number, :turn_number, :attackers, :occurred_at]

  @type attacker :: %{arena_id: integer() | nil, instance_id: integer()}

  @type t :: %__MODULE__{
          player_id: integer() | nil,
          mtga_match_id: String.t() | nil,
          game_number: non_neg_integer() | nil,
          turn_number: non_neg_integer() | nil,
          attackers: [attacker()],
          occurred_at: DateTime.t()
        }

  def from_payload(payload) do
    %__MODULE__{
      player_id: payload["player_id"],
      mtga_match_id: payload["mtga_match_id"],
      game_number: payload["game_number"],
      turn_number: payload["turn_number"],
      attackers: payload["attackers"] || [],
      occurred_at: Payload.parse_datetime(payload["occurred_at"])
    }
  end

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "attackers_declared"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
