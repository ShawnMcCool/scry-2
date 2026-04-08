defmodule Scry2.Events.Event.EventJoined do
  @moduledoc """
  Domain event — the player joined an MTGA event (draft, sealed,
  constructed queue, etc.) and paid the entry fee.

  ## Slug

  `"event_joined"` — stable, do not rename.

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a raw
  `EventJoin` response (the `<==` variant carrying `Course` +
  `InventoryInfo`). The companion `InventoryChanged` event captures
  the currency delta from the same response.
  """

  @enforce_keys [:event_name, :occurred_at]
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

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "event_joined"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
