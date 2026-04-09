defmodule Scry2.Events.Progression.WeeklyWinEarned do
  @moduledoc """
  The player advanced their weekly win reward position.

  Event type: :state_change

  ## Source

  Emitted by `SnapshotConvert` when a changed `WeeklyWinsStatus` shows a higher
  weekly position than the previous snapshot. Mirrors `DailyWinEarned` for the
  weekly track.

  ## Fields

  - `player_id` — MTGA player identifier
  - `new_position` — the weekly tier now unlocked
  - `occurred_at` — when the win was observed

  ## Slug

  `"weekly_win_earned"` — stable, do not rename.
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
    def type_slug(_), do: "weekly_win_earned"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
