defmodule Scry2.Events.PrizeClaimed do
  @moduledoc """
  Domain event — the player claimed prizes from a completed MTGA
  event (draft, sealed, etc.). Captures the final win/loss record.

  ## Slug

  `"prize_claimed"` — stable, do not rename.

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a raw
  `EventClaimPrize` response. The companion `InventoryChanged`
  event(s) from the same response capture the actual rewards received.
  """

  @enforce_keys [:event_name, :occurred_at]
  defstruct [
    :player_id,
    :event_name,
    :course_id,
    :wins,
    :losses,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          event_name: String.t(),
          course_id: String.t() | nil,
          wins: non_neg_integer() | nil,
          losses: non_neg_integer() | nil,
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "prize_claimed"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
