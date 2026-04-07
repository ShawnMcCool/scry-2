defmodule Scry2.Events.MasteryProgress do
  @moduledoc """
  Domain event — a point-in-time snapshot of the player's progression
  through an MTGA graph (tutorial steps, mastery pass levels, colour
  mastery quests, spark ranks).

  ## Slug

  `"mastery_progress"` — stable, do not rename.

  ## Source

  Produced from `GraphGetGraphState` response events. Request events
  (with `"request"` key) are skipped — they carry only the `GraphId`
  parameter with no node data.

  The response carries `NodeStates` — a map of node IDs to their
  completion status — and optionally `MilestoneStates` — a map of
  milestone flags. Both are preserved in full per the maximal detail
  principle.
  """

  @enforce_keys [:node_states, :occurred_at]
  defstruct [
    :player_id,
    :node_states,
    :milestone_states,
    :total_nodes,
    :completed_nodes,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          node_states: %{String.t() => map()},
          milestone_states: %{String.t() => boolean()} | nil,
          total_nodes: non_neg_integer(),
          completed_nodes: non_neg_integer(),
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "mastery_progress"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
