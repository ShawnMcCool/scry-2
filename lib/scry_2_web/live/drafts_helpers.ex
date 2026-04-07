defmodule Scry2Web.DraftsHelpers do
  @moduledoc """
  Pure helper functions for `Scry2Web.DraftsLive`. Extracted per ADR-013.
  """

  @doc "Format a win-loss record for display."
  @spec win_loss_label(integer() | nil, integer() | nil) :: String.t()
  def win_loss_label(wins, losses), do: "#{wins || 0}-#{losses || 0}"

  @doc "Returns a human label for draft completion status."
  @spec draft_status_label(map()) :: String.t()
  def draft_status_label(%{completed_at: nil}), do: "In progress"
  def draft_status_label(_draft), do: "Complete"
end
