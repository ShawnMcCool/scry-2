defmodule Scry2.Collection.SetCompletion do
  @moduledoc """
  Per-set playset completeness — partitions a set's cards into three
  buckets (missing / partial / complete) and a per-rarity breakdown.

  Pure value derived from a `%Scry2.Cards.Set{}`, the booster-legal cards
  in that set (obtained via `Scry2.Cards.list_booster_cards_by_set/1`),
  and a list of `%Scry2.Collection.Holding{}`.

  Holdings whose `card.set_id` does not match the given set are silently
  ignored — callers may pass the full collection holdings list without
  pre-filtering.

  Buckets:

    * `:missing`  — card has no holding (or holding count = 0)
    * `:partial`  — holding has 1, 2, or 3 copies
    * `:complete` — holding has 4 or more copies (a full playset)
  """

  alias Scry2.Cards.{Card, Set}
  alias Scry2.Collection.Holding

  @enforce_keys [:set, :buckets, :by_rarity]
  defstruct [:set, :buckets, :by_rarity]

  @type bucket :: %{
          missing: [Card.t()],
          partial: [Holding.t()],
          complete: [Holding.t()]
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
  def from(%Set{id: set_id} = set, set_cards, holdings)
      when is_list(set_cards) and is_list(holdings) do
    holdings_by_arena_id =
      holdings
      |> Enum.filter(&(&1.card.set_id == set_id))
      |> Map.new(&{&1.arena_id, &1})

    %__MODULE__{
      set: set,
      buckets: build_buckets(set_cards, holdings_by_arena_id),
      by_rarity: build_by_rarity(set_cards, holdings_by_arena_id)
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

  defp build_buckets(set_cards, holdings_by_arena_id) do
    {missing, partial, complete} =
      Enum.reduce(set_cards, {[], [], []}, fn card, {missing, partial, complete} ->
        case bucket_key(card, holdings_by_arena_id) do
          :missing ->
            {[card | missing], partial, complete}

          :partial ->
            {missing, [Map.fetch!(holdings_by_arena_id, card.arena_id) | partial], complete}

          :complete ->
            {missing, partial, [Map.fetch!(holdings_by_arena_id, card.arena_id) | complete]}
        end
      end)

    %{
      missing: Enum.reverse(missing),
      partial: Enum.reverse(partial),
      complete: Enum.reverse(complete)
    }
  end

  defp build_by_rarity(set_cards, holdings_by_arena_id) do
    Enum.reduce(set_cards, %{}, fn card, acc ->
      rarity = card.rarity || "unknown"
      key = bucket_key(card, holdings_by_arena_id)

      acc
      |> Map.put_new(rarity, empty_rarity_bucket())
      |> update_in([rarity, key], &(&1 + 1))
      |> update_in([rarity, :total], &(&1 + 1))
    end)
  end

  defp bucket_key(card, holdings_by_arena_id) do
    case Map.get(holdings_by_arena_id, card.arena_id) do
      nil -> :missing
      %Holding{count: count} when count >= @playset -> :complete
      %Holding{count: count} when count >= 1 -> :partial
      _ -> :missing
    end
  end

  defp empty_rarity_bucket, do: %{missing: 0, partial: 0, complete: 0, total: 0}
end
