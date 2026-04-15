defmodule Scry2.Events.Stack.TargetsDeclared do
  @moduledoc """
  The local player submitted targets for a spell or ability.

  ## Source
  Produced by `IdentifyDomainEvents.ClientToGre` from
  `ClientMessageType_SubmitTargets` with a non-empty targets list.

  ## Fields
  - `spell_instance_id` — GRE instance ID of the spell/ability on the stack
  - `targets` — list of `%{instance_id: integer, arena_id: integer}` maps
  """
  @behaviour Scry2.Events.DomainEvent
  alias Scry2.Events.Payload
  @enforce_keys [:occurred_at]
  defstruct [
    :player_id,
    :mtga_match_id,
    :game_number,
    :turn_number,
    :spell_instance_id,
    :targets,
    :occurred_at
  ]

  @type target :: %{instance_id: integer(), arena_id: integer() | nil}

  @type t :: %__MODULE__{
          player_id: integer() | nil,
          mtga_match_id: String.t() | nil,
          game_number: non_neg_integer() | nil,
          turn_number: non_neg_integer() | nil,
          spell_instance_id: integer() | nil,
          targets: [target()],
          occurred_at: DateTime.t()
        }

  def from_payload(payload) do
    %__MODULE__{
      player_id: payload["player_id"],
      mtga_match_id: payload["mtga_match_id"],
      game_number: payload["game_number"],
      turn_number: payload["turn_number"],
      spell_instance_id: payload["spell_instance_id"],
      targets: payload["targets"] || [],
      occurred_at: Payload.parse_datetime(payload["occurred_at"])
    }
  end

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "targets_declared"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
