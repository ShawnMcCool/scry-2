defmodule Scry2.Events.Permanent.PermanentTapped do
  @moduledoc """
  A permanent became tapped (state change detected from `gameObjects[]`).

  ## Source

  Produced by `IdentifyDomainEvents.GameStateMessage` when a game object's
  `isTapped` field changes from false to true between consecutive messages.

  ## Fields

  - `arena_id` — arena_id of the permanent that was tapped
  - `instance_id` — GRE instance ID of the permanent on the battlefield
  - `phase` — game phase when the tap occurred

  ## Slug

  `"permanent_tapped"` — stable, do not rename.
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
    :arena_id,
    :instance_id,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: integer() | nil,
          mtga_match_id: String.t() | nil,
          game_number: non_neg_integer() | nil,
          turn_number: non_neg_integer() | nil,
          phase: String.t() | nil,
          arena_id: integer() | nil,
          instance_id: integer() | nil,
          occurred_at: DateTime.t()
        }

  def from_payload(payload) do
    %__MODULE__{
      player_id: payload["player_id"],
      mtga_match_id: payload["mtga_match_id"],
      game_number: payload["game_number"],
      turn_number: payload["turn_number"],
      phase: payload["phase"],
      arena_id: payload["arena_id"],
      instance_id: payload["instance_id"],
      occurred_at: Payload.parse_datetime(payload["occurred_at"])
    }
  end

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "permanent_tapped"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
