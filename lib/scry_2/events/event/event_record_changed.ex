defmodule Scry2.Events.Event.EventRecordChanged do
  @moduledoc """
  An MTGA event course record changed — win/loss record, active module, or card pool.

  Event type: :state_change

  ## Source

  Emitted by `SnapshotConvert` from a changed `EventCourseUpdated` snapshot.
  Fires when any aspect of the event course differs from the previous state.
  Also emitted on first observation.

  ## Fields

  - `player_id` — MTGA player identifier
  - `event_name` — MTGA event identifier
  - `wins` — current wins in this event
  - `losses` — current losses in this event
  - `current_module` — active event stage (e.g. `"Draft"`, `"Play"`)
  - `card_pool` — arena_ids in the player's event card pool
  - `occurred_at` — when the change was observed

  ## Slug

  `"event_record_changed"` — stable, do not rename.
  """

  @enforce_keys [:event_name, :occurred_at]
  @behaviour Scry2.Events.DomainEvent

  alias Scry2.Events.Payload

  defstruct [
    :player_id,
    :event_name,
    :wins,
    :losses,
    :current_module,
    :card_pool,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          event_name: String.t(),
          wins: non_neg_integer() | nil,
          losses: non_neg_integer() | nil,
          current_module: String.t() | nil,
          card_pool: [integer()] | nil,
          occurred_at: DateTime.t()
        }

  def from_payload(payload) do
    %__MODULE__{
      player_id: payload["player_id"],
      event_name: payload["event_name"],
      wins: payload["wins"],
      losses: payload["losses"],
      current_module: payload["current_module"],
      card_pool: payload["card_pool"],
      occurred_at: Payload.parse_datetime(payload["occurred_at"])
    }
  end

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "event_record_changed"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
