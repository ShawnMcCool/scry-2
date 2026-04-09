defmodule Scry2.Events.Progression.QuestStatus do
  @moduledoc """
  Snapshot of the player's currently assigned quests and their progress.

  Event type: :snapshot

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a raw `QuestGetQuests`
  response. Fires on login and periodic sync. Each quest in the array includes
  its goal, current progress, and reward description.

  ## Fields

  - `player_id` — MTGA player identifier
  - `quests` — list of quest maps, each with `quest_id`, `goal`, `progress`,
    `quest_track`, `reward_gold`, and `reward_xp`

  ## Diff key

  `SnapshotDiff` compares the list of `{quest_id, goal, progress, quest_track}`
  tuples per quest. `reward_gold` and `reward_xp` are excluded from the diff key
  as they are static reward metadata that does not change with progress.

  ## Slug

  `"quest_status"` — stable, do not rename.
  """

  @enforce_keys [:quests, :occurred_at]
  defstruct [
    :player_id,
    :quests,
    :occurred_at
  ]

  @type quest :: %{
          quest_id: String.t(),
          goal: non_neg_integer(),
          progress: non_neg_integer(),
          quest_track: String.t() | nil,
          reward_gold: integer() | nil,
          reward_xp: integer() | nil
        }

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          quests: [quest()],
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "quest_status"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
