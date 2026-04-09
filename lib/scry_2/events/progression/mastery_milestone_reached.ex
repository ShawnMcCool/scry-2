defmodule Scry2.Events.Progression.MasteryMilestoneReached do
  @moduledoc """
  A mastery pass milestone was unlocked.

  Event type: :state_change

  ## Source

  Emitted by `SnapshotConvert` once per newly unlocked milestone when a
  `MasteryProgress` snapshot shows a milestone that was absent or false in the
  previous state but is now true. One event per milestone key.

  ## Fields

  - `player_id` — MTGA player identifier
  - `milestone_key` — the milestone ID that was unlocked (key from milestone_states map)
  - `occurred_at` — when the milestone unlock was observed

  ## Slug

  `"mastery_milestone_reached"` — stable, do not rename.
  """

  @enforce_keys [:milestone_key, :occurred_at]
  @behaviour Scry2.Events.DomainEvent

  alias Scry2.Events.Payload

  defstruct [
    :player_id,
    :milestone_key,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          milestone_key: String.t(),
          occurred_at: DateTime.t()
        }

  def from_payload(payload) do
    %__MODULE__{
      player_id: payload["player_id"],
      milestone_key: payload["milestone_key"],
      occurred_at: Payload.parse_datetime(payload["occurred_at"])
    }
  end

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "mastery_milestone_reached"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
