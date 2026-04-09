defmodule Scry2.Events.Progression.MasteryProgress do
  @moduledoc """
  Point-in-time snapshot of the player's progression through an MTGA graph
  (tutorial steps, mastery pass levels, colour mastery quests, spark ranks).

  Event type: :snapshot

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a raw `GraphGetGraphState`
  response. Fires on login and periodic sync. Request events (with a `"request"`
  key) are skipped — they carry only the `GraphId` parameter with no node data.
  The response carries `NodeStates` (a map of node IDs to completion status) and
  optionally `MilestoneStates` (a map of milestone flags), both preserved in full.

  ## Fields

  - `player_id` — MTGA player identifier
  - `node_states` — map of node ID => completion state for every graph node
  - `milestone_states` — map of milestone ID => boolean for milestone flags
  - `total_nodes` — total number of nodes in the graph
  - `completed_nodes` — count of nodes in a completed state

  ## Diff key

  `SnapshotDiff` compares `{completed_nodes, milestone_states}`.
  `node_states` is excluded from the diff key — it is a large map and
  `completed_nodes` captures the meaningful progression signal. Milestone
  states are included because they represent distinct reward unlocks.

  ## Slug

  `"mastery_progress"` — stable, do not rename.
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
