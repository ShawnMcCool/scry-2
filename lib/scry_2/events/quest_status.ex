defmodule Scry2.Events.QuestStatus do
  @moduledoc """
  Domain event — snapshot of the player's currently assigned quests
  and their progress.

  ## Slug

  `"quest_status"` — stable, do not rename.

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a raw
  `QuestGetQuests` response. Each quest in the array includes its
  goal, current progress, and reward description.
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
