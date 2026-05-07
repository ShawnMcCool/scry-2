defmodule Scry2Web.Collection.AcquisitionHistory do
  @moduledoc """
  A short feed of recent collection diffs — one row each, newest first.
  Complements `RecentAcquisitions` (which shows the full breakdown of
  the latest diff only).
  """

  use Phoenix.Component

  import Scry2Web.LiveHelpers, only: [relative_time: 1]

  attr :diffs, :list, required: true

  def acquisition_history(%{diffs: []} = assigns), do: ~H""

  def acquisition_history(assigns) do
    ~H"""
    <div class="card bg-base-200 border border-base-300 max-w-3xl" data-role="acquisition-history">
      <div class="card-body">
        <h2 class="card-title">Acquisition history</h2>
        <ul class="divide-y divide-base-300">
          <li
            :for={diff <- @diffs}
            class="py-2 flex items-center justify-between text-sm"
            data-role="acquisition-row"
          >
            <span
              class="text-base-content/60"
              title={Calendar.strftime(diff.inserted_at, "%Y-%m-%d %H:%M UTC")}
            >
              {relative_time(diff.inserted_at)}
            </span>
            <span class="flex items-center gap-3 tabular-nums">
              <span :if={diff.total_acquired > 0} class="badge badge-soft badge-success badge-sm">
                +{diff.total_acquired}
              </span>
              <span :if={diff.total_removed > 0} class="badge badge-soft badge-warning badge-sm">
                −{diff.total_removed}
              </span>
              <span
                :if={diff.total_acquired == 0 and diff.total_removed == 0}
                class="text-base-content/40"
              >
                no change
              </span>
            </span>
          </li>
        </ul>
      </div>
    </div>
    """
  end
end
