defmodule Scry2Web.Collection.CraftPlan do
  @moduledoc """
  Renders a `Scry2.Collection.CraftPlan.t()` — wildcard balance row plus
  the list of incomplete playsets.

  Pure renderer. The playset table caps at 100 rows for performance; the
  total count is rendered above the table.
  """

  use Phoenix.Component

  import Scry2Web.CardComponents, only: [card_name: 1]
  import Scry2Web.CoreComponents, only: [stat_card: 1, wildcard_icon: 1]

  alias Scry2.Collection.CraftPlan, as: CraftPlanStruct

  @rarities ~w(mythic rare uncommon common)

  attr :value, :any, required: true
  attr :cached_ids, :any, default: nil

  def craft_plan(assigns) do
    plan = assigns.value
    gap = CraftPlanStruct.gap(plan)
    visible = Enum.take(plan.incomplete_playsets, 100)

    assigns =
      assign(assigns,
        rarities: @rarities,
        gap: gap,
        visible: visible,
        total_count: length(plan.incomplete_playsets)
      )

    ~H"""
    <div class="card bg-base-200 border border-base-300" data-role="craft-plan">
      <div class="card-body space-y-4">
        <h2 class="card-title">Craft plan</h2>

        <div class="grid grid-cols-2 sm:grid-cols-4 gap-3" data-role="wildcards-needed">
          <.stat_card
            :for={rarity <- @rarities}
            title={"#{String.capitalize(rarity)} wildcards"}
            value={tile_value(@gap[rarity], @value.wildcards_owned[rarity])}
            data-stat={"wc-gap-#{rarity}"}
          >
            <:icon><.wildcard_icon rarity={rarity} /></:icon>
          </.stat_card>
        </div>

        <div :if={@total_count == 0} class="text-sm text-base-content/60">
          No incomplete playsets. Your collection is complete!
        </div>

        <div :if={@total_count > 0} class="space-y-2">
          <p class="text-xs text-base-content/60 tabular-nums">
            Showing {length(@visible)} of {@total_count} cards needing copies.
          </p>
          <div class="overflow-x-auto">
            <table class="table table-sm" data-role="incomplete-playsets">
              <thead>
                <tr>
                  <th class="text-left">Card</th>
                  <th class="text-left">Rarity</th>
                  <th class="text-right">Owned</th>
                  <th class="text-right">Needed</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={row <- @visible}
                  data-role="incomplete-playset-row"
                  data-arena-id={row.holding.arena_id}
                >
                  <td class="truncate max-w-xs">
                    <.card_name
                      arena_id={row.holding.arena_id}
                      name={row.holding.card.name || "—"}
                      cached_ids={@cached_ids}
                    />
                  </td>
                  <td class="capitalize">{row.holding.card.rarity || "—"}</td>
                  <td class="text-right tabular-nums">{row.holding.count}/4</td>
                  <td class="text-right tabular-nums">{row.copies_needed}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp tile_value(0, owned), do: "Have #{owned || 0}"
  defp tile_value(gap, owned), do: "#{gap} more (have #{owned || 0})"
end
