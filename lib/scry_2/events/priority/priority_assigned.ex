defmodule Scry2.Events.Priority.PriorityAssigned do
  @moduledoc """
  Priority was assigned to a player.

  ## Source
  Produced by `IdentifyDomainEvents.GameStateMessage` when the GRE assigns
  priority to a seat (server → client). Emitted on change only.
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
    :step,
    :player_seat,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: integer() | nil,
          mtga_match_id: String.t() | nil,
          game_number: non_neg_integer() | nil,
          turn_number: non_neg_integer() | nil,
          phase: String.t() | nil,
          step: String.t() | nil,
          player_seat: integer() | nil,
          occurred_at: DateTime.t()
        }

  def from_payload(payload) do
    %__MODULE__{
      player_id: payload["player_id"],
      mtga_match_id: payload["mtga_match_id"],
      game_number: payload["game_number"],
      turn_number: payload["turn_number"],
      phase: payload["phase"],
      step: payload["step"],
      player_seat: payload["player_seat"],
      occurred_at: Payload.parse_datetime(payload["occurred_at"])
    }
  end

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "priority_assigned"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
