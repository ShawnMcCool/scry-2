defmodule Scry2.MatchEconomy.AggregateLog do
  @moduledoc """
  Aggregates log-derived economy state over a match window into per-currency
  deltas the way `Compute.diffs/2` expects.

  Two underlying sources:

    * `Economy.Transaction` — discrete gold/gems deltas from
      `InventoryChanged` events. Summed inclusively over the window.
    * `Economy.InventorySnapshot` — full balances from `InventoryUpdated`
      events. Wildcard deltas come from diffing the most-recent snapshots
      on either side of the window.

  Returns nil for a currency when its source data is unavailable.
  """

  import Ecto.Query
  alias Scry2.Repo
  alias Scry2.Economy.Transaction
  alias Scry2.Economy.InventorySnapshot

  @doc """
  Gold and gems delta from `Economy.Transaction` rows with `occurred_at`
  in `[start_at, end_at]` (inclusive).
  """
  @spec gold_gems(DateTime.t(), DateTime.t()) :: %{gold: integer(), gems: integer()}
  def gold_gems(start_at, end_at) do
    from(t in Transaction,
      where: t.occurred_at >= ^start_at and t.occurred_at <= ^end_at,
      select: %{
        gold: coalesce(sum(t.gold_delta), 0),
        gems: coalesce(sum(t.gems_delta), 0)
      }
    )
    |> Repo.one()
  end

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
    pre = latest_snapshot_at_or_before(start_at)
    post = latest_snapshot_at_or_before(end_at)

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

  defp latest_snapshot_at_or_before(ts) do
    from(s in InventorySnapshot,
      where: s.occurred_at <= ^ts,
      order_by: [desc: s.occurred_at],
      limit: 1
    )
    |> Repo.one()
  end

  defp sub(nil, _), do: nil
  defp sub(_, nil), do: nil
  defp sub(a, b), do: a - b
end
