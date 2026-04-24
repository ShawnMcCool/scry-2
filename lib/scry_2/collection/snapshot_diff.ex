defmodule Scry2.Collection.SnapshotDiff do
  @moduledoc """
  Pure-function diff between two `Scry2.Collection.Snapshot` rows.

  Since MTGA stopped writing per-card grant events to `Player.log`
  (2021.8.0.3855), the only ground truth for card acquisition is the
  memory snapshot. This module computes the per-card delta between
  consecutive snapshots — the substrate for the acquisition ledger.

  ## Returned shape

      %{
        acquired: %{arena_id => count_added, ...},
        removed:  %{arena_id => count_lost,  ...}
      }

  When `prev` is `nil`, every card in `next` with a positive count is
  reported as `acquired` — first-snapshot baseline.
  """

  alias Scry2.Collection.Snapshot

  @type arena_id :: integer()
  @type counts :: %{arena_id() => non_neg_integer()}
  @type t :: %{acquired: counts(), removed: counts()}

  @spec diff(Snapshot.t() | nil, Snapshot.t()) :: t()
  def diff(nil, %Snapshot{} = next) do
    acquired =
      next
      |> decode()
      |> Map.reject(fn {_arena_id, count} -> count <= 0 end)

    %{acquired: acquired, removed: %{}}
  end

  def diff(%Snapshot{} = prev, %Snapshot{} = next) do
    prev_counts = decode(prev)
    next_counts = decode(next)

    arena_ids =
      prev_counts
      |> Map.keys()
      |> Enum.concat(Map.keys(next_counts))
      |> Enum.uniq()

    {acquired, removed} =
      Enum.reduce(arena_ids, {%{}, %{}}, fn arena_id, {acc_added, acc_removed} ->
        old_count = Map.get(prev_counts, arena_id, 0)
        new_count = Map.get(next_counts, arena_id, 0)

        cond do
          new_count > old_count ->
            {Map.put(acc_added, arena_id, new_count - old_count), acc_removed}

          new_count < old_count ->
            {acc_added, Map.put(acc_removed, arena_id, old_count - new_count)}

          true ->
            {acc_added, acc_removed}
        end
      end)

    %{acquired: acquired, removed: removed}
  end

  @spec totals(t()) :: %{total_acquired: non_neg_integer(), total_removed: non_neg_integer()}
  def totals(%{acquired: acquired, removed: removed}) do
    %{
      total_acquired: acquired |> Map.values() |> Enum.sum(),
      total_removed: removed |> Map.values() |> Enum.sum()
    }
  end

  defp decode(%Snapshot{cards_json: json}) when is_binary(json) do
    json
    |> Snapshot.decode_entries()
    |> Map.new()
  end
end
