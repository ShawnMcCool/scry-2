defmodule Scry2.Events.Progression.DailyWinsStatus do
  @moduledoc """
  Snapshot of the player's daily and weekly win reward progress and next
  reset times.

  Event type: :snapshot

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a raw
  `PeriodicRewardsGetStatus` response. Fires on login and during periodic
  sync. The position fields indicate the next reward tier to be earned
  (1 = no wins yet today/this week).

  ## Fields

  - `player_id` — MTGA player identifier
  - `daily_position` — next daily win reward tier to be unlocked (1 = first)
  - `daily_reset_at` — when the daily win counter resets
  - `weekly_position` — next weekly win reward tier to be unlocked (1 = first)
  - `weekly_reset_at` — when the weekly win counter resets

  ## Diff key

  `SnapshotDiff` compares `{daily_position, weekly_position}`. Reset times
  (`daily_reset_at`, `weekly_reset_at`) are excluded — they change on a fixed
  schedule and would generate spurious events without a corresponding progress
  change.

  ## Slug

  `"daily_wins_status"` — stable, do not rename.
  """

  @enforce_keys [:daily_position, :occurred_at]
  @behaviour Scry2.Events.DomainEvent

  alias Scry2.Events.Payload

  defstruct [
    :player_id,
    :daily_position,
    :daily_reset_at,
    :weekly_position,
    :weekly_reset_at,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          daily_position: non_neg_integer(),
          daily_reset_at: DateTime.t() | nil,
          weekly_position: non_neg_integer() | nil,
          weekly_reset_at: DateTime.t() | nil,
          occurred_at: DateTime.t()
        }

  def from_payload(payload) do
    %__MODULE__{
      player_id: payload["player_id"],
      daily_position: payload["daily_position"],
      daily_reset_at: payload["daily_reset_at"],
      weekly_position: payload["weekly_position"],
      weekly_reset_at: payload["weekly_reset_at"],
      occurred_at: Payload.parse_datetime(payload["occurred_at"])
    }
  end

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "daily_wins_status"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
