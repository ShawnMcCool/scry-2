defmodule Scry2.Events.Priority.PriorityPassed do
  @moduledoc """
  The local player explicitly passed priority.

  ## Source
  Produced by `IdentifyDomainEvents.ClientToGre` from
  `ClientToGremessage` with `ClientMessageType_PerformActionResp` carrying
  an empty or pass action. Only fires for the local player — opponent passes
  are implicit (see `PriorityAssigned` switching back to us).
  """
  @behaviour Scry2.Events.DomainEvent
  alias Scry2.Events.Payload
  @enforce_keys [:occurred_at]
  defstruct [:player_id, :mtga_match_id, :game_number, :turn_number, :phase, :step, :occurred_at]

  @type t :: %__MODULE__{
          player_id: integer() | nil,
          mtga_match_id: String.t() | nil,
          game_number: non_neg_integer() | nil,
          turn_number: non_neg_integer() | nil,
          phase: String.t() | nil,
          step: String.t() | nil,
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
      occurred_at: Payload.parse_datetime(payload["occurred_at"])
    }
  end

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "priority_passed"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
