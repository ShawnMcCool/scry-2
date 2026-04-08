defmodule Scry2.Events.Event.PairingEntered do
  @moduledoc """
  Domain event — the player entered the match queue (pairing) for
  an MTGA event. The timestamp marks the moment they clicked "Play."

  ## Slug

  `"pairing_entered"` — stable, do not rename.

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a raw
  `EventEnterPairing` request.
  """

  @enforce_keys [:event_name, :occurred_at]
  defstruct [
    :player_id,
    :event_name,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          event_name: String.t(),
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "pairing_entered"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
