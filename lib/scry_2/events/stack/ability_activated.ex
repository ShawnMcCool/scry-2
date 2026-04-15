defmodule Scry2.Events.Stack.AbilityActivated do
  @moduledoc """
  A player activated an activated ability (cost: effect).

  ## Source

  Produced by `IdentifyDomainEvents.GameStateMessage` from
  `AnnotationType_ActivatedAbility` annotations in `GameStateMessage`.

  ## Fields

  - `source_arena_id` — arena_id of the permanent whose ability was activated
  - `source_instance_id` — GRE instance ID of the permanent on the battlefield

  ## Slug

  `"ability_activated"` — stable, do not rename.
  """
  @behaviour Scry2.Events.DomainEvent
  alias Scry2.Events.Payload
  @enforce_keys [:occurred_at]
  defstruct [
    :player_id,
    :mtga_match_id,
    :game_number,
    :turn_number,
    :phase,
    :source_arena_id,
    :source_instance_id,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: integer() | nil,
          mtga_match_id: String.t() | nil,
          game_number: non_neg_integer() | nil,
          turn_number: non_neg_integer() | nil,
          phase: String.t() | nil,
          source_arena_id: integer() | nil,
          source_instance_id: integer() | nil,
          occurred_at: DateTime.t()
        }

  def from_payload(payload) do
    %__MODULE__{
      player_id: payload["player_id"],
      mtga_match_id: payload["mtga_match_id"],
      game_number: payload["game_number"],
      turn_number: payload["turn_number"],
      phase: payload["phase"],
      source_arena_id: payload["source_arena_id"],
      source_instance_id: payload["source_instance_id"],
      occurred_at: Payload.parse_datetime(payload["occurred_at"])
    }
  end

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "ability_activated"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
