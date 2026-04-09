defmodule Scry2.Events.Event.PairingEntered do
  @moduledoc """
  The player entered the match queue for an MTGA event. The timestamp marks
  the moment they clicked "Play" and the queue search began.

  Event type: :state_change

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a raw `EventEnterPairing`
  request. Fires when the player submits the request to enter the pairing queue.

  ## Fields

  - `player_id` — MTGA player identifier
  - `event_name` — internal MTGA event identifier for the event being queued for

  ## Slug

  `"pairing_entered"` — stable, do not rename.
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
