defmodule Scry2.Events.Progression.QuestProgressed do
  @moduledoc """
  An existing quest advanced in progress but has not yet been completed.

  Event type: :state_change

  ## Source

  Emitted by `SnapshotConvert` when a quest_id present in both old and new
  `QuestStatus` shows a higher progress value. Fires when progress increases
  but has not reached the goal.

  ## Fields

  - `player_id` — MTGA player identifier
  - `quest_id` — the quest that progressed
  - `new_progress` — updated progress count
  - `goal` — total required to complete
  - `occurred_at` — when the progress was observed

  ## Slug

  `"quest_progressed"` — stable, do not rename.
  """

  @enforce_keys [:quest_id, :new_progress, :goal, :occurred_at]
  defstruct [
    :player_id,
    :quest_id,
    :new_progress,
    :goal,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          quest_id: String.t(),
          new_progress: non_neg_integer(),
          goal: non_neg_integer(),
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "quest_progressed"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
