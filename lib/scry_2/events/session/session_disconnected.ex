defmodule Scry2.Events.Session.SessionDisconnected do
  @moduledoc """
  Domain event — the player disconnected from MTGA servers. Useful for
  session duration analytics and connection stability tracking.

  ## Slug

  `"session_disconnected"` — stable, do not rename.

  ## Source

  Produced from `FrontDoorConnection.Close` raw events.
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
