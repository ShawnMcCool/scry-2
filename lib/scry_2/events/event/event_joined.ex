defmodule Scry2.Events.Event.EventJoined do
  @moduledoc """
  The player joined an MTGA event and paid the entry fee. A companion
  `InventoryChanged` event captures the currency delta from the same response.

  Event type: :state_change

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a raw `EventJoin`
  response (the `<==` variant carrying `Course` + `InventoryInfo`). Fires when
  the server confirms the player has entered an event (draft, sealed, constructed
  queue, etc.).

  ## Fields

  - `player_id` — MTGA player identifier
  - `event_name` — internal MTGA event identifier for the joined event
  - `course_id` — MTGA course identifier for this specific run of the event
  - `entry_currency_type` — currency used to enter (e.g. `"Gold"`, `"Gem"`)
  - `entry_fee` — amount of currency paid to enter

  ## Slug

  `"event_joined"` — stable, do not rename.
  """

  @enforce_keys [:event_name, :occurred_at]
  @behaviour Scry2.Events.DomainEvent

  alias Scry2.Events.Payload

  defstruct [
    :player_id,
    :event_name,
    :course_id,
    :entry_currency_type,
    :entry_fee,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          event_name: String.t(),
          course_id: String.t() | nil,
          entry_currency_type: String.t() | nil,
          entry_fee: integer() | nil,
          occurred_at: DateTime.t()
        }

  def from_payload(payload) do
    %__MODULE__{
      player_id: payload["player_id"],
      event_name: payload["event_name"],
      course_id: payload["course_id"],
      entry_currency_type: payload["entry_currency_type"],
      entry_fee: payload["entry_fee"],
      occurred_at: Payload.parse_datetime(payload["occurred_at"])
    }
  end

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "event_joined"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
