defmodule Scry2.Events.ActiveCourses do
  @moduledoc """
  Domain event — snapshot of all MTGA events (courses) the player
  is currently enrolled in, with their win/loss records.

  ## Slug

  `"active_courses"` — stable, do not rename.

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a raw
  `EventGetCoursesV2` response.
  """

  @enforce_keys [:courses, :occurred_at]
  defstruct [
    :player_id,
    :courses,
    :occurred_at
  ]

  @type course :: %{
          course_id: String.t(),
          event_name: String.t(),
          current_module: String.t() | nil,
          wins: non_neg_integer() | nil,
          losses: non_neg_integer() | nil
        }

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          courses: [course()],
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "active_courses"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
