defmodule Scry2.Events.Progression.DailyWinsStatus do
  @moduledoc """
  Domain event — snapshot of the player's daily and weekly win
  reward progress and next reset times.

  ## Slug

  `"daily_wins_status"` — stable, do not rename.

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a raw
  `PeriodicRewardsGetStatus` response. The position fields indicate
  the next reward tier to be earned (1 = no wins yet today/this week).
  """

  @enforce_keys [:daily_position, :occurred_at]
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

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "daily_wins_status"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
