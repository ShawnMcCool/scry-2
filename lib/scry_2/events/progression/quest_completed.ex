defmodule Scry2.Events.Progression.QuestCompleted do
  @moduledoc """
  A quest was completed and removed from the active quest list.

  Event type: :state_change

  ## Source

  Emitted by `SnapshotConvert` when a quest_id that was present in the previous
  `QuestStatus` is absent in the new one, indicating it was completed (and
  likely replaced). One event per disappeared quest_id.

  ## Fields

  - `player_id` — MTGA player identifier
  - `quest_id` — the quest that was completed/replaced
  - `occurred_at` — when the completion was observed

  ## Slug

  `"quest_completed"` — stable, do not rename.
  """

  @enforce_keys [:quest_id, :occurred_at]
  defstruct [
    :player_id,
    :quest_id,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          quest_id: String.t(),
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "quest_completed"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
