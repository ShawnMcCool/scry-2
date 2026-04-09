defmodule Scry2.Events.Event.EventCourseUpdated do
  @moduledoc """
  Snapshot of the current state of an MTGA event course — win/loss record,
  active module, and card pool for draft/sealed events.

  Event type: :snapshot

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from `EventGetCoursesV2`
  (periodic course sync). Fires once per active course per sync. Each course
  represents an ongoing or recently completed event.

  ## Fields

  - `player_id` — MTGA player identifier
  - `event_name` — internal MTGA event identifier (e.g. `"QuickDraft_BLB_20250101"`)
  - `current_wins` — number of wins accumulated in this event
  - `current_losses` — number of losses accumulated in this event
  - `current_module` — active stage of the event (e.g. `"Draft"`, `"Play"`)
  - `card_pool` — list of arena_ids for the player's sealed or draft card pool

  ## Diff key

  `SnapshotDiff` compares `{event_name, current_wins, current_losses,
  current_module, card_pool}`. Changes to any of these trigger a new event.
  `player_id` and `occurred_at` are excluded (metadata).

  ## Slug

  `"event_course_updated"` — stable, do not rename.
  """

  @enforce_keys [:event_name, :occurred_at]
  defstruct [
    :player_id,
    :event_name,
    :current_wins,
    :current_losses,
    :current_module,
    :card_pool,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: integer() | nil,
          event_name: String.t(),
          current_wins: non_neg_integer() | nil,
          current_losses: non_neg_integer() | nil,
          current_module: String.t() | nil,
          card_pool: [integer()] | nil,
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "event_course_updated"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
