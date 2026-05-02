defmodule Scry2.Collection.PendingPacks do
  @moduledoc """
  Summarizes a collection snapshot's unopened booster inventory by set
  code.

  The walker reads `ClientPlayerInventory.boosters: List<ClientBoosterInfo>`
  per spike 18 and persists each `{collation_id, count}` row in
  `collection_snapshots.boosters_json`. This module:

    1. decodes the JSON,
    2. resolves each `collation_id` → set_code via
       `Scry2.Cards.BoosterCollation.lookup/1`,
    3. merges rows that share a set_code,
    4. sorts by count desc.

  Pure — the lookup function is injected so the module is unit-testable
  without seeding the real disk-backed cache.
  """

  alias Scry2.Cards.BoosterCollation
  alias Scry2.Collection.Snapshot

  @type row :: %{set_code: String.t() | nil, count: integer()}

  @doc """
  Returns one row per distinct set_code, sorted by count desc.
  Collation ids the lookup function can't resolve are bucketed under
  `set_code: nil`. Zero-count rows are dropped.

  Accepts either `%Snapshot{}` or `nil`; the latter is handy when
  callers pass `Scry2.Collection.current()` (which returns `nil` when
  no snapshots have been captured yet).
  """
  @spec summarize(Snapshot.t() | nil, (integer() -> String.t() | nil)) :: [row()]
  def summarize(snapshot, lookup \\ &BoosterCollation.lookup/1)

  def summarize(nil, _lookup), do: []

  def summarize(%Snapshot{boosters_json: nil}, _lookup), do: []

  def summarize(%Snapshot{boosters_json: json}, lookup) when is_function(lookup, 1) do
    json
    |> Snapshot.decode_boosters()
    |> Enum.reject(fn {_cid, count} -> count <= 0 end)
    |> Enum.group_by(fn {cid, _} -> lookup.(cid) end, fn {_, count} -> count end)
    |> Enum.map(fn {set_code, counts} -> %{set_code: set_code, count: Enum.sum(counts)} end)
    |> Enum.sort_by(& &1.count, :desc)
  end

  @doc "Sums the `count` field across summary rows."
  @spec total([row()]) :: integer()
  def total(rows) when is_list(rows) do
    Enum.reduce(rows, 0, fn %{count: count}, acc -> acc + count end)
  end
end
