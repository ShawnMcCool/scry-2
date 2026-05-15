defmodule Scry2Web.Collection.SetDetail.SetSummary do
  @moduledoc """
  Hybrid summary band for the set-detail page:

    * Three stat cards across the top — Missing / Partial / Complete
      (counts of cards in each playset state for this set).
    * A per-rarity row block beneath, with a stacked progress bar
      (complete + partial segments) and the playset-complete fraction.
  """

  use Phoenix.Component

  import Scry2Web.CoreComponents, only: [stat_card: 1]

  alias Scry2.Collection.SetCompletion

  # Most-rare → least-rare. Mythic on top to match how players reason about
  # the set ("which mythics am I missing?").
  @rarity_order ~w(mythic rare uncommon common)

  attr :completion, SetCompletion, required: true

  def set_summary(assigns) do
    totals = SetCompletion.totals(assigns.completion)
    rarity_rows = build_rarity_rows(assigns.completion)

    assigns =
      assigns
      |> assign(:totals, totals)
      |> assign(:rarity_rows, rarity_rows)

    ~H"""
    <div class="space-y-4" data-role="set-summary">
      <div class="grid grid-cols-1 sm:grid-cols-3 gap-4" data-role="set-summary-stats">
        <.stat_card title="Missing" value={@totals.missing} data-stat="missing" />
        <.stat_card title="Partial" value={@totals.partial} data-stat="partial" />
        <.stat_card title="Complete playsets" value={@totals.complete} data-stat="complete" />
      </div>

      <div class="card bg-base-200 border border-base-300" data-role="set-summary-rarity">
        <div class="card-body p-4 space-y-3">
          <p class="text-xs uppercase text-base-content/60">By rarity</p>
          <div class="space-y-2">
            <.rarity_row :for={row <- @rarity_rows} {row} />
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :rarity, :string, required: true
  attr :missing, :integer, required: true
  attr :partial, :integer, required: true
  attr :complete, :integer, required: true
  attr :total, :integer, required: true

  defp rarity_row(assigns) do
    ~H"""
    <div
      class="grid grid-cols-12 items-center gap-2 text-sm"
      data-role="rarity-row"
      data-rarity={@rarity}
    >
      <div class="col-span-2 text-base-content/80 text-xs uppercase tracking-wide">
        {label(@rarity)}
      </div>
      <div class="col-span-7">
        <div class="flex w-full h-2 bg-base-300 rounded overflow-hidden" title={tooltip(assigns)}>
          <div
            class="bg-emerald-500/60"
            style={"width: #{percent(@complete, @total)}%"}
            data-segment="complete"
          />
          <div
            class="bg-amber-500/50"
            style={"width: #{percent(@partial, @total)}%"}
            data-segment="partial"
          />
        </div>
      </div>
      <div class="col-span-3 text-right tabular-nums text-xs text-base-content/70">
        <span class="text-base-content">{@complete}</span>
        <span class="text-base-content/50">/</span>
        <span>{@total}</span>
        <span class="text-base-content/50 ml-1">playsets</span>
      </div>
    </div>
    """
  end

  defp build_rarity_rows(%SetCompletion{by_rarity: by_rarity}) do
    Enum.flat_map(@rarity_order, fn rarity ->
      case Map.get(by_rarity, rarity) do
        nil -> []
        bucket -> [Map.put(bucket, :rarity, rarity)]
      end
    end)
  end

  defp label("mythic"), do: "Mythic"
  defp label("rare"), do: "Rare"
  defp label("uncommon"), do: "Uncommon"
  defp label("common"), do: "Common"
  defp label(other), do: String.capitalize(other)

  defp percent(_n, 0), do: 0
  defp percent(n, total), do: Float.round(n / total * 100, 1)

  defp tooltip(%{complete: c, partial: p, missing: m, total: t}) do
    "#{c} complete · #{p} partial · #{m} missing · #{t} total"
  end
end
