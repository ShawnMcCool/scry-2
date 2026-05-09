defmodule Scry2.MatchEconomy.AggregateLog do
  @moduledoc """
  Aggregates log-derived economy state over a match window into per-currency
  deltas the way `Compute.diffs/2` expects.

  Two underlying sources, both consumed through the `Scry2.Economy` public
  API rather than reaching into Economy's internal schemas:

    * `Economy.sum_gold_gems_in_window/2` — discrete gold/gems deltas
      summed inclusively over the window.
    * `Economy.latest_inventory_snapshot_at_or_before/1` — full-balance
      snapshots used to compute wildcard deltas across the window.

  Returns nil for a currency when its source data is unavailable.
  """

  alias Scry2.Economy

  @doc """
  Gold and gems delta from `Economy.Transaction` rows with `occurred_at`
  in `[start_at, end_at]` (inclusive).
  """
  @spec gold_gems(DateTime.t(), DateTime.t()) :: %{gold: integer(), gems: integer()}
  def gold_gems(start_at, end_at), do: Economy.sum_gold_gems_in_window(start_at, end_at)

  @doc """
  Wildcard delta computed from the most-recent `InventorySnapshot` rows
  at or before `start_at` and at or before `end_at`. Returns all-nil
  when either side has no snapshot.
  """
  @spec wildcards(DateTime.t(), DateTime.t()) ::
          %{
            common: integer() | nil,
            uncommon: integer() | nil,
            rare: integer() | nil,
            mythic: integer() | nil
          }
  def wildcards(start_at, end_at) do
    pre = Economy.latest_inventory_snapshot_at_or_before(start_at)
    post = Economy.latest_inventory_snapshot_at_or_before(end_at)

    cond do
      is_nil(pre) or is_nil(post) ->
        %{common: nil, uncommon: nil, rare: nil, mythic: nil}

      true ->
        %{
          common: sub(post.wildcards_common, pre.wildcards_common),
          uncommon: sub(post.wildcards_uncommon, pre.wildcards_uncommon),
          rare: sub(post.wildcards_rare, pre.wildcards_rare),
          mythic: sub(post.wildcards_mythic, pre.wildcards_mythic)
        }
    end
  end

  @doc """
  Public combined log-delta map for a match window. Combines gold/gems
  (from Transactions) with wildcards (from InventorySnapshot bracketing).
  """
  @spec over(DateTime.t(), DateTime.t()) :: map()
  def over(start_at, end_at) do
    %{gold: gold, gems: gems} = gold_gems(start_at, end_at)

    %{common: common, uncommon: uncommon, rare: rare, mythic: mythic} =
      wildcards(start_at, end_at)

    %{
      gold: gold,
      gems: gems,
      wildcards_common: common,
      wildcards_uncommon: uncommon,
      wildcards_rare: rare,
      wildcards_mythic: mythic
    }
  end

  defp sub(nil, _), do: nil
  defp sub(_, nil), do: nil
  defp sub(a, b), do: a - b
end
