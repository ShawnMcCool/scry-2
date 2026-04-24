defmodule Scry2.Collection.Diff do
  @moduledoc """
  An immutable record of the per-card delta between two consecutive
  `Scry2.Collection.Snapshot` rows.

  Persisted in the same transaction as the newer snapshot. The
  `from_snapshot_id` is `nil` only for the very first snapshot ever
  recorded, where every owned card is a baseline acquisition.

  Acquired/removed payloads are stored as JSON maps keyed by
  arena_id (string in storage, integer at the boundary). See
  `Scry2.Collection.SnapshotDiff` for the pure computation.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Scry2.Collection.Snapshot

  @type counts :: %{integer() => non_neg_integer()}
  @type t :: %__MODULE__{}

  @cast_fields [
    :from_snapshot_id,
    :to_snapshot_id,
    :cards_added_json,
    :cards_removed_json,
    :total_acquired,
    :total_removed
  ]

  @required_fields [
    :to_snapshot_id,
    :cards_added_json,
    :cards_removed_json,
    :total_acquired,
    :total_removed
  ]

  schema "collection_diffs" do
    belongs_to :from_snapshot, Snapshot
    belongs_to :to_snapshot, Snapshot

    field :cards_added_json, :string
    field :cards_removed_json, :string
    field :total_acquired, :integer
    field :total_removed, :integer

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(diff, attrs) do
    attrs = normalise(attrs)

    diff
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_number(:total_acquired, greater_than_or_equal_to: 0)
    |> validate_number(:total_removed, greater_than_or_equal_to: 0)
    |> unique_constraint([:from_snapshot_id, :to_snapshot_id])
    |> unique_constraint(:to_snapshot_id)
  end

  @doc "Encodes a counts map (arena_id => count) as the canonical JSON blob."
  @spec encode_counts(counts()) :: String.t()
  def encode_counts(counts) when is_map(counts) do
    counts
    |> Enum.map(fn {arena_id, count} -> %{"arena_id" => arena_id, "count" => count} end)
    |> Jason.encode!()
  end

  @doc "Decodes a counts JSON blob back into a map."
  @spec decode_counts(String.t()) :: counts()
  def decode_counts(json) when is_binary(json) do
    json
    |> Jason.decode!()
    |> Map.new(fn %{"arena_id" => arena_id, "count" => count} -> {arena_id, count} end)
  end

  defp normalise(%{acquired: acquired, removed: removed} = attrs) do
    attrs
    |> Map.delete(:acquired)
    |> Map.delete(:removed)
    |> Map.put_new(:cards_added_json, encode_counts(acquired))
    |> Map.put_new(:cards_removed_json, encode_counts(removed))
    |> Map.put_new(:total_acquired, sum(acquired))
    |> Map.put_new(:total_removed, sum(removed))
  end

  defp normalise(attrs), do: attrs

  defp sum(counts), do: counts |> Map.values() |> Enum.sum()
end
