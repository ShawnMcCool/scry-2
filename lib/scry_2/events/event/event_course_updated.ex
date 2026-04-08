defmodule Scry2.Events.Event.EventCourseUpdated do
  @moduledoc """
  Domain event — an MTGA event course (draft, sealed, etc.) state update.

  ## Slug

  `"event_course_updated"` — stable, do not rename.

  ## Source

  Produced from `EventGetCoursesV2` (periodic state sync) and
  `EventClaimPrize` (after claiming rewards). Each course represents
  an active or completed event with win/loss record and card pool.
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
