defmodule Scry2Web.DashboardHelpers do
  @moduledoc """
  Pure helper functions for `Scry2Web.DashboardLive`. Extracted per
  ADR-013 (LiveView logic extraction) so they can be unit-tested
  without mounting a LiveView or touching the database.
  """

  @doc """
  Returns a human-readable label for the watcher status map.
  """
  @spec watcher_label(map()) :: String.t()
  def watcher_label(%{state: :running}), do: "Running"
  def watcher_label(%{state: :starting}), do: "Starting..."
  def watcher_label(%{state: :path_not_found}), do: "Path not found"
  def watcher_label(%{state: :path_missing}), do: "File missing"
  def watcher_label(%{state: :not_running}), do: "Stopped"
  def watcher_label(_), do: "Unknown"

  @doc """
  True when the dashboard should show the "detailed logs required"
  warning banner — i.e. when the watcher has indicated it can't find
  the log file.
  """
  @spec show_detailed_logs_warning?(map()) :: boolean()
  def show_detailed_logs_warning?(%{state: state})
      when state in [:path_not_found, :path_missing, :not_running] do
    true
  end

  def show_detailed_logs_warning?(_), do: false

  @doc """
  Returns event type counts sorted in descending count order.
  """
  @spec sort_events_by_count(map()) :: [{String.t(), non_neg_integer()}]
  def sort_events_by_count(map) when is_map(map) do
    map
    |> Enum.to_list()
    |> Enum.sort_by(fn {_, count} -> -count end)
  end
end
