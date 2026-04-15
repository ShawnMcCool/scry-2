defmodule Scry2.Events.Permanent.PermanentStatsChanged do
  @moduledoc """
  A permanent's power or toughness changed (continuous effect applied or removed).

  ## Source
  Produced by `IdentifyDomainEvents.GameStateMessage` when a game object's
  `power` or `toughness` value changes between consecutive `GameStateMessage`
  messages. Captures effects like Giant Growth that are not modelled as counters.
  """
  @behaviour Scry2.Events.DomainEvent
  alias Scry2.Events.Payload
  @enforce_keys [:occurred_at]
  defstruct [:player_id, :mtga_match_id, :game_number, :turn_number, :phase,
             :arena_id, :instance_id, :power, :toughness, :occurred_at]

  @type t :: %__MODULE__{
          player_id: integer() | nil,
          mtga_match_id: String.t() | nil,
          game_number: non_neg_integer() | nil,
          turn_number: non_neg_integer() | nil,
          phase: String.t() | nil,
          arena_id: integer() | nil,
          instance_id: integer() | nil,
          power: integer() | nil,
          toughness: integer() | nil,
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
      power: payload["power"],
      toughness: payload["toughness"],
      occurred_at: Payload.parse_datetime(payload["occurred_at"])
    }
  end

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "permanent_stats_changed"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
