defmodule Scry2.Events.Progression.DailyWinEarned do
  @moduledoc """
  The player advanced their daily win reward position.

  Event type: :state_change

  ## Source

  Emitted by `SnapshotConvert` when a changed `DailyWinsStatus` shows a higher
  `daily_position` than the previous snapshot. Does NOT fire on reset (position
  decrease) or on first observation.

  ## Fields

  - `player_id` — MTGA player identifier
  - `new_position` — the daily tier now unlocked (was one step lower before)
  - `occurred_at` — when the win was observed

  ## Slug

  `"daily_win_earned"` — stable, do not rename.
  """

  @enforce_keys [:new_position, :occurred_at]
  defstruct [
    :player_id,
    :new_position,
    :occurred_at
  ]

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          new_position: non_neg_integer(),
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "daily_win_earned"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
