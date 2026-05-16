defmodule Scry2.Collection.SetCompletion do
  @moduledoc """
  Per-set playset completeness — partitions a set's cards into three
  buckets (missing / partial / complete) and a per-rarity breakdown.

  Pure value derived from a `%Scry2.Cards.Set{}`, the booster-legal cards
  in that set (obtained via `Scry2.Cards.list_booster_cards_by_set/1`),
  and a list of `%Scry2.Collection.Holding{}`.

  ## Rolling up duplicate printings

  MTGA tracks each art printing (regular, alternate, borderless, showcase,
  etc.) under its own `arena_id` — but it caps **playsets by oracle
  name**, not by printing. If a player owns 4 copies of Essence Scatter
  across any combination of sets, MTGA shows a complete playset for
  every set that reprints it, and further copies become vault progress.

  This module mirrors that reality by summing copies across every
  printing of a name that the player owns, then capping at a playset of
  4. The canonical display card is the lowest-numbered printing in the
  set being viewed.

  Callers pass the full collection holdings list; cross-set printings of
  the same card name *do* count toward the playset, but holdings of
  unrelated card names from other sets are ignored.

  ## Bucket shape

  Every bucket holds `{canonical_card, summed_count}` tuples — uniform
  across all three buckets so consumers don't have to handle two shapes:

    * `:missing`  — summed_count = 0 (no holding for any printing)
    * `:partial`  — summed_count in 1..3
    * `:complete` — summed_count >= 4 (a full playset)

  `:by_rarity` counts canonical cards (so one "Emeritus of Truce" with
  two printings counts as a single mythic, not two).
  """

  alias Scry2.Cards.{Card, Set}
  alias Scry2.Collection.Holding

  @enforce_keys [:set, :buckets, :by_rarity]
  defstruct [:set, :buckets, :by_rarity]

  @type rolled :: {Card.t(), non_neg_integer()}

  @type bucket :: %{
          missing: [rolled()],
          partial: [rolled()],
          complete: [rolled()]
        }

  @type rarity_bucket :: %{
          missing: non_neg_integer(),
          partial: non_neg_integer(),
          complete: non_neg_integer(),
          total: non_neg_integer()
        }

  @type t :: %__MODULE__{
          set: Set.t(),
          buckets: bucket(),
          by_rarity: %{String.t() => rarity_bucket()}
        }

  @playset 4

  @spec from(Set.t(), [Card.t()], [Holding.t()]) :: t()
  def from(%Set{} = set, set_cards, holdings)
      when is_list(set_cards) and is_list(holdings) do
    counts_by_name =
      Enum.reduce(holdings, %{}, fn h, acc ->
        Map.update(acc, h.card.name, h.count, &(&1 + h.count))
      end)

    rolled = roll_up_by_name(set_cards, counts_by_name)

    %__MODULE__{
      set: set,
      buckets: build_buckets(rolled),
      by_rarity: build_by_rarity(rolled)
    }
  end

  @doc """
  Aggregates the buckets into total counts across all rarities.
  """
  @spec totals(t()) :: %{
          missing: non_neg_integer(),
          partial: non_neg_integer(),
          complete: non_neg_integer(),
          total: non_neg_integer()
        }
  def totals(%__MODULE__{buckets: buckets}) do
    missing = length(buckets.missing)
    partial = length(buckets.partial)
    complete = length(buckets.complete)
    %{missing: missing, partial: partial, complete: complete, total: missing + partial + complete}
  end

  # Returns [{canonical_card, capped_count}, ...] in stable input order
  # by canonical card's collector number. The count comes from the
  # name-rollup of the entire collection (not just this set), capped at
  # a playset of 4 because MTGA does not distinguish printings when
  # filling the playset cap.
  defp roll_up_by_name(cards, counts_by_name) do
    cards
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn {name, printings} ->
      canonical = Enum.min_by(printings, &collector_sort_key(&1.collector_number))
      total = min(Map.get(counts_by_name, name, 0), @playset)
      {canonical, total}
    end)
  end

  defp build_buckets(rolled) do
    {missing, partial, complete} =
      Enum.reduce(rolled, {[], [], []}, fn {card, count} = entry, {missing, partial, complete} ->
        cond do
          count >= @playset -> {missing, partial, [entry | complete]}
          count >= 1 -> {missing, [entry | partial], complete}
          true -> {[{card, 0} | missing], partial, complete}
        end
      end)

    %{
      missing: Enum.reverse(missing),
      partial: Enum.reverse(partial),
      complete: Enum.reverse(complete)
    }
  end

  defp build_by_rarity(rolled) do
    Enum.reduce(rolled, %{}, fn {card, count}, acc ->
      rarity = card.rarity || "unknown"
      key = bucket_key(count)

      acc
      |> Map.put_new(rarity, empty_rarity_bucket())
      |> update_in([rarity, key], &(&1 + 1))
      |> update_in([rarity, :total], &(&1 + 1))
    end)
  end

  defp bucket_key(count) when count >= @playset, do: :complete
  defp bucket_key(count) when count >= 1, do: :partial
  defp bucket_key(_count), do: :missing

  defp empty_rarity_bucket, do: %{missing: 0, partial: 0, complete: 0, total: 0}

  # Collector numbers can include suffixes ("5a", "★12") on promos. Sort
  # by leading integer so the lowest plain number wins as the canonical
  # printing; numeric-with-suffix beats non-numeric.
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
