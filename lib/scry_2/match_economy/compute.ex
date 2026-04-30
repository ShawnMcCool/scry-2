defmodule Scry2.MatchEconomy.Compute do
  @moduledoc """
  Pure functions for computing memory deltas, log/memory diffs, and
  reconciliation state from snapshot + log inputs. Side-effect-free.

  See ADR-036 §3.
  """

  alias Scry2.Collection.Snapshot

  @currency_keys [
    :gold,
    :gems,
    :wildcards_common,
    :wildcards_uncommon,
    :wildcards_rare,
    :wildcards_mythic
  ]

  @doc """
  Computes per-currency `post − pre`. Returns a map with keys
  `:gold`, `:gems`, `:wildcards_common/uncommon/rare/mythic`, `:vault`.
  Any value nil if pre or post is nil, or if the underlying Snapshot
  field is nil on either side.
  """
  @spec memory_deltas(Snapshot.t() | nil, Snapshot.t() | nil) :: map()
  def memory_deltas(nil, _), do: nil_deltas()
  def memory_deltas(_, nil), do: nil_deltas()

  def memory_deltas(%Snapshot{} = pre, %Snapshot{} = post) do
    integer_deltas =
      for key <- @currency_keys, into: %{} do
        {key, sub(Map.get(post, key), Map.get(pre, key))}
      end

    Map.put(integer_deltas, :vault, vault_sub(post.vault_progress, pre.vault_progress))
  end

  @doc """
  Per-currency `memory − log`. Returns nil for any currency where either
  side is nil. Vault has no log analog and is not included.
  """
  @spec diffs(map(), map()) :: map()
  def diffs(memory, log) do
    for key <- @currency_keys, into: %{} do
      {key, sub(Map.get(memory, key), Map.get(log, key))}
    end
  end

  defp sub(nil, _), do: nil
  defp sub(_, nil), do: nil
  defp sub(a, b), do: a - b

  defp vault_sub(nil, _), do: nil
  defp vault_sub(_, nil), do: nil
  defp vault_sub(a, b), do: Float.round(a - b, 4)

  defp nil_deltas do
    %{
      gold: nil,
      gems: nil,
      wildcards_common: nil,
      wildcards_uncommon: nil,
      wildcards_rare: nil,
      wildcards_mythic: nil,
      vault: nil
    }
  end
end
