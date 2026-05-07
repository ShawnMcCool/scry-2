defmodule Scry2Web.Collection.RecentAcquisitions do
  @moduledoc """
  Renders the most recent `Scry2.Collection.Diff` as a compact card with
  acquired and removed entries broken out.

  Pure renderer over a `Diff.t()` plus a `cards_by_arena_id` lookup map.
  """

  use Phoenix.Component

  import Scry2Web.LiveHelpers, only: [relative_time: 1]

  alias Scry2.Collection.DiffView

  attr :diff, :any, required: true
  attr :cards, :map, required: true

  def recent_acquisitions(%{diff: nil} = assigns), do: ~H""

  def recent_acquisitions(assigns) do
    assigns =
      assign(assigns,
        acquired: DiffView.entries(assigns.diff.cards_added_json, assigns.cards),
        removed: DiffView.entries(assigns.diff.cards_removed_json, assigns.cards)
      )

    ~H"""
    <div class="card bg-base-200 border border-base-300 max-w-3xl" data-role="recent-acquisitions">
      <div class="card-body">
        <h2 class="card-title">Recent acquisitions</h2>
        <p
          class="text-xs text-base-content/60"
          title={Calendar.strftime(@diff.inserted_at, "%Y-%m-%d %H:%M UTC")}
        >
          {relative_time(@diff.inserted_at)} · +{@diff.total_acquired} · −{@diff.total_removed}
        </p>

        <div :if={@acquired != []} class="mt-3">
          <div class="text-xs uppercase tracking-wide text-base-content/60 mb-1">Acquired</div>
          <ul class="space-y-1" data-role="diff-acquired">
            <li :for={entry <- @acquired} class="flex items-center gap-2 text-sm">
              <span class="badge badge-soft badge-success badge-sm tabular-nums">
                +{entry.count}
              </span>
              <span class="truncate">{entry.name}</span>
            </li>
          </ul>
        </div>

        <div :if={@removed != []} class="mt-3">
          <div class="text-xs uppercase tracking-wide text-base-content/60 mb-1">Removed</div>
          <ul class="space-y-1" data-role="diff-removed">
            <li :for={entry <- @removed} class="flex items-center gap-2 text-sm">
              <span class="badge badge-soft badge-warning badge-sm tabular-nums">
                −{entry.count}
              </span>
              <span class="truncate">{entry.name}</span>
            </li>
          </ul>
        </div>

        <div :if={@acquired == [] and @removed == []} class="mt-3 text-sm text-base-content/60">
          No card changes since the previous snapshot.
        </div>
      </div>
    </div>
    """
  end
end
