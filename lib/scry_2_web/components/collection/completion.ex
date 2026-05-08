defmodule Scry2Web.Collection.Completion do
  @moduledoc """
  Renders the per-set completion grid — one tile per set with rarity-banded
  progress bars. Clicking a tile patches the URL with `?set=CODE` so the
  Holding browser scopes to that set.

  Pure renderer over a `[Scry2.Collection.Completion.t()]`. Host LiveView
  must implement `phx-click="select_set"` to handle the patch.
  """

  use Phoenix.Component

  import Scry2Web.CoreComponents, only: [set_label: 1]

  alias Scry2.Collection.Completion, as: CompletionStruct

  # Most-rare → least-rare. Mythic on the left, common on the right
  # so the eye lands on the high-impact rarities first when scanning
  # a row of set tiles.
  @rarity_order ~w(mythic rare uncommon common)

  attr :rows, :list, required: true
  attr :active_set, :any, default: nil

  def completion(%{rows: []} = assigns) do
    ~H"""
    <div class="card bg-base-200 border border-base-300" data-role="completion">
      <div class="card-body">
        <h2 class="card-title">Set completion</h2>
        <p class="text-sm text-base-content/60">No card reference data imported yet.</p>
      </div>
    </div>
    """
  end

  def completion(assigns) do
    assigns = assign(assigns, rarity_order: @rarity_order)

    ~H"""
    <div class="card bg-base-200 border border-base-300" data-role="completion">
      <div class="card-body space-y-4">
        <h2 class="card-title">Set completion</h2>

        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3">
          <button
            :for={row <- @rows}
            type="button"
            phx-click="select_set"
            phx-value-set={row.set.code}
            class={[
              "card card-compact bg-base-100 border text-left hover:border-primary",
              if(row.set.code == @active_set,
                do: "border-primary",
                else: "border-base-300"
              )
            ]}
            data-role="completion-tile"
            data-set={row.set.code}
          >
            <div class="card-body p-3 space-y-2">
              <div class="flex items-baseline justify-between gap-2">
                <.set_label set={row.set} class="font-semibold text-sm" />
                <span class="text-xs text-base-content/60 tabular-nums shrink-0">
                  {row.owned_unique}/{row.total_unique}
                </span>
              </div>

              <div class="flex gap-1">
                <.rarity_bar
                  :for={rarity <- @rarity_order}
                  :if={Map.has_key?(row.by_rarity, rarity)}
                  rarity={rarity}
                  bucket={Map.fetch!(row.by_rarity, rarity)}
                />
              </div>

              <div class="text-xs text-base-content/60 tabular-nums">
                {percent(CompletionStruct.completion_ratio(row))}%
              </div>
            </div>
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :rarity, :string, required: true
  attr :bucket, :map, required: true

  defp rarity_bar(assigns) do
    assigns =
      assign(assigns,
        bar_class: rarity_class(assigns.rarity),
        rarity_letter: rarity_letter(assigns.rarity)
      )

    ~H"""
    <div
      class="flex-1 min-w-0"
      title={"#{String.capitalize(@rarity)}: #{@bucket.owned}/#{@bucket.total}"}
    >
      <div class="flex items-center gap-1 text-[10px] text-base-content/60">
        <span>{@rarity_letter}</span>
        <span class="tabular-nums ml-auto">{@bucket.owned}/{@bucket.total}</span>
      </div>
      <div class="h-1.5 w-full bg-base-300 rounded">
        <div class={[@bar_class, "h-1.5 rounded"]} style={"width: #{progress(@bucket)}%"} />
      </div>
    </div>
    """
  end

  defp rarity_class("common"), do: "bg-base-content/40"
  defp rarity_class("uncommon"), do: "bg-sky-500/70"
  defp rarity_class("rare"), do: "bg-amber-500/70"
  defp rarity_class("mythic"), do: "bg-rose-500/70"
  defp rarity_class(_), do: "bg-base-content/30"

  defp rarity_letter("common"), do: "C"
  defp rarity_letter("uncommon"), do: "U"
  defp rarity_letter("rare"), do: "R"
  defp rarity_letter("mythic"), do: "M"
  defp rarity_letter(other) when is_binary(other), do: String.first(other)

  defp progress(%{total: 0}), do: 0
  defp progress(%{owned: o, total: t}) when t > 0, do: Float.round(o / t * 100, 1)

  defp percent(ratio), do: Float.round(ratio * 100, 1)
end
