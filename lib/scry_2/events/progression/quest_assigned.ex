defmodule Scry2.Events.Progression.QuestAssigned do
  @moduledoc """
  A new quest was assigned to the player.

  Event type: :state_change

  ## Source

  Emitted by `SnapshotConvert` when a quest_id appears in the current
  `QuestStatus` that was not in the previous state. Also emitted on first
  observation (nil previous state) for every quest in the initial snapshot.

  ## Fields

  - `player_id` — MTGA player identifier
  - `quest_id` — the newly assigned quest
  - `goal` — required progress to complete
  - `quest_track` — quest category track (e.g. `"Daily"`, `"Weekly"`)
  - `occurred_at` — when the assignment was observed

  ## Slug

  `"quest_assigned"` — stable, do not rename.
  """

  @enforce_keys [:quest_id, :goal, :occurred_at]
  defstruct [
    :player_id,
    :quest_id,
    :goal,
    :quest_track,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          quest_id: String.t(),
          goal: non_neg_integer(),
          quest_track: String.t() | nil,
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "quest_assigned"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
