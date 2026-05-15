defmodule Scry2Web.Collection.SetDetail.GapList do
  @moduledoc """
  Renders the gap-card grid grouped by rarity (Mythic → Rare → Uncommon
  → Common). Within each section cards are sorted by collector number.

  Cards in the `:complete` bucket (full playset already owned) are
  intentionally excluded — the page is about gaps.
  """

  use Phoenix.Component

  import Scry2Web.Collection.SetDetail.GapCard, only: [gap_card: 1]

  alias Scry2.Collection.SetCompletion

  # Most-rare → least-rare. Players prioritise Mythics/Rares when opening
  # packs, so they read first.
  @rarity_order ~w(mythic rare uncommon common)

  attr :completion, SetCompletion, required: true
  attr :cached_arena_ids, :any, default: nil

  def gap_list(assigns) do
    sections = build_sections(assigns.completion)
    assigns = assign(assigns, :sections, sections)

    ~H"""
    <div class="space-y-6" data-role="gap-list">
      <div
        :if={all_complete?(@sections)}
        class="card bg-base-200 border border-base-300"
        data-role="all-complete"
      >
        <div class="card-body">
          <p class="text-sm text-base-content/80">
            No gaps in this set — every booster card is at a complete playset.
          </p>
        </div>
      </div>

      <section
        :for={{rarity, gaps} <- @sections}
        :if={gaps != []}
        data-role="gap-section"
        data-rarity={rarity}
        class="space-y-3"
      >
        <h3 class="text-xs uppercase tracking-wide text-base-content/60">
          {rarity_label(rarity)} gaps ({length(gaps)})
        </h3>
        <div class="flex flex-wrap gap-3">
          <.gap_card
            :for={{card, count} <- gaps}
            card={card}
            count={count}
            cached_arena_ids={@cached_arena_ids}
          />
        </div>
      </section>
    </div>
    """
  end

  # Returns [{rarity, [{card, count}, ...]}, ...] in rarity order, with
  # the count being how many copies the player owns (0 for missing,
  # 1-3 for partial). Cards at full playset are not included.
  defp build_sections(%SetCompletion{buckets: buckets}) do
    missing_with_count = Enum.map(buckets.missing, &{&1, 0})
    partial_with_count = Enum.map(buckets.partial, &{&1.card, &1.count})

    grouped =
      (missing_with_count ++ partial_with_count)
      |> Enum.group_by(fn {card, _count} -> card.rarity || "unknown" end)

    Enum.map(@rarity_order, fn rarity ->
      gaps = Map.get(grouped, rarity, [])

      sorted =
        Enum.sort_by(gaps, fn {card, _count} -> collector_sort_key(card.collector_number) end)

      {rarity, sorted}
    end)
  end

  defp all_complete?(sections), do: Enum.all?(sections, fn {_, gaps} -> gaps == [] end)

  defp rarity_label("mythic"), do: "Mythic"
  defp rarity_label("rare"), do: "Rare"
  defp rarity_label("uncommon"), do: "Uncommon"
  defp rarity_label("common"), do: "Common"
  defp rarity_label(other), do: String.capitalize(other)

  # Collector numbers are usually integers but can include suffixes
  # ("5a", "★12") on promos / variants. Sort by leading integer; entries
  # with no leading digits sort to the end.
  defp collector_sort_key(nil), do: {1, 0, ""}
  defp collector_sort_key(""), do: {1, 0, ""}
  defp collector_sort_key(n) when is_integer(n), do: {0, n, ""}

  defp collector_sort_key(n) when is_binary(n) do
    case Integer.parse(n) do
      {num, rest} -> {0, num, rest}
      :error -> {1, 0, n}
    end
  end
end
