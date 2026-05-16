defmodule Scry2.Events.CatchUpStatus do
  @moduledoc """
  Classifies the projector pipeline's catch-up state from a snapshot of
  `Scry2.Events.ProjectorRegistry.status_all/0` output.

  Pure function. No DB, no PubSub, no side effects — the caller is
  responsible for sampling the status_all snapshot and deciding what to
  do with the result (typically: render a "catching up" banner while the
  pipeline absorbs a burst of work after an update or reingest).

  ## When the banner should show

  The banner is meant to explain *visible* lag — small per-event
  background catch-up isn't worth taking up screen real estate. A total
  lag below `@min_visible_lag` events is treated as "caught up" for
  banner purposes even when one or more projectors haven't ticked their
  watermark to the very latest event.
  """

  @min_visible_lag 50

  @type projector_status :: %{
          required(:name) => String.t(),
          required(:watermark) => non_neg_integer(),
          required(:max_event_id) => non_neg_integer(),
          required(:caught_up) => boolean(),
          optional(atom()) => term()
        }

  @type t :: %{
          caught_up: boolean(),
          lag: non_neg_integer(),
          projectors_behind: [{String.t(), non_neg_integer()}]
        }

  @doc """
  Returns `%{caught_up, lag, projectors_behind}` for the given list of
  per-projector status maps (the shape returned by
  `Scry2.Events.ProjectorRegistry.status_all/0`).

    * `:caught_up` — `true` when the aggregate lag is below
      `#{@min_visible_lag}` events. Drives banner visibility.
    * `:lag` — sum of `max_event_id - watermark` across every
      not-caught-up projector. Negative differences are clamped to 0
      (defensive against stale snapshots where a projector reports a
      watermark briefly past its own max_event_id between writes).
    * `:projectors_behind` — list of `{name, lag}` pairs for projectors
      that are not caught up. Ordered most-behind first to make
      "longest pole" obvious in the UI.
  """
  @spec compute([projector_status()]) :: t()
  def compute(projector_statuses) when is_list(projector_statuses) do
    behind = Enum.reject(projector_statuses, & &1.caught_up)

    projectors_behind =
      behind
      |> Enum.map(fn s -> {s.name, max(s.max_event_id - s.watermark, 0)} end)
      |> Enum.sort_by(fn {_name, lag} -> lag end, :desc)

    total_lag = Enum.sum_by(projectors_behind, fn {_name, lag} -> lag end)

    %{
      caught_up: total_lag < @min_visible_lag,
      lag: total_lag,
      projectors_behind: projectors_behind
    }
  end

  @doc "Threshold (events) below which lag is treated as 'caught up'."
  @spec min_visible_lag() :: pos_integer()
  def min_visible_lag, do: @min_visible_lag
end
