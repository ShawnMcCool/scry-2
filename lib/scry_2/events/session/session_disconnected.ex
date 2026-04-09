defmodule Scry2.Events.Session.SessionDisconnected do
  @moduledoc """
  The player disconnected from MTGA servers. Useful for session duration
  analytics and connection stability tracking.

  Event type: :state_change

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a raw
  `FrontDoorConnection.Close` event. Fires when the MTGA client closes
  its connection to the front-door service.

  ## Fields

  - `player_id` — MTGA player identifier (may be nil if set before disconnect)

  ## Slug

  `"session_disconnected"` — stable, do not rename.
  """

  @enforce_keys [:occurred_at]
  defstruct [
    :player_id,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "session_disconnected"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
