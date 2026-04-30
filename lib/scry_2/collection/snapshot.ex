defmodule Scry2.Collection.Snapshot do
  @moduledoc """
  One capture of the player's MTGA card collection from process memory.

  Append-only. The `cards_json` column holds the canonical list of
  `%{arena_id, count}` entries as a JSON blob — keeping the schema flat
  (no child table) so a snapshot round-trips as one row regardless of
  collection size.

  Walker-path fields (`wildcards_*`, `gold`, `gems`, `vault_progress`)
  are nullable — the scanner fallback can't populate them yet. The
  walker implementation lands them (ADR 034).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type entry :: {arena_id :: integer(), count :: integer()}
  @type t :: %__MODULE__{}

  @reader_confidences ~w(walker fallback_scan)
  @match_phases ~w(pre post)

  @cast_fields [
    :snapshot_ts,
    :reader_version,
    :reader_confidence,
    :mtga_build_hint,
    :card_count,
    :total_copies,
    :cards_json,
    :wildcards_common,
    :wildcards_uncommon,
    :wildcards_rare,
    :wildcards_mythic,
    :gold,
    :gems,
    :vault_progress,
    :mtga_match_id,
    :match_phase
  ]

  @required_fields [
    :snapshot_ts,
    :reader_version,
    :reader_confidence,
    :card_count,
    :total_copies,
    :cards_json
  ]

  schema "collection_snapshots" do
    field :snapshot_ts, :utc_datetime_usec
    field :reader_version, :string
    field :reader_confidence, :string
    field :mtga_build_hint, :string
    field :card_count, :integer
    field :total_copies, :integer
    field :cards_json, :string
    field :wildcards_common, :integer
    field :wildcards_uncommon, :integer
    field :wildcards_rare, :integer
    field :wildcards_mythic, :integer
    field :gold, :integer
    field :gems, :integer
    field :vault_progress, :float
    field :mtga_match_id, :string
    field :match_phase, :string

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Builds a changeset from a map of attrs.

  Accepts `:entries` as shorthand — when present it's JSON-encoded
  into `:cards_json` (and `:card_count` / `:total_copies` are derived
  if not explicitly supplied).
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(snapshot, attrs) do
    attrs = normalise_entries(attrs)

    snapshot
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:reader_confidence, @reader_confidences)
    |> validate_inclusion(:match_phase, @match_phases)
    |> validate_number(:card_count, greater_than_or_equal_to: 0)
    |> validate_number(:total_copies, greater_than_or_equal_to: 0)
  end

  @doc "Encodes an entries list as the canonical JSON blob."
  @spec encode_entries([entry()]) :: String.t()
  def encode_entries(entries) do
    entries
    |> Enum.map(fn {arena_id, count} -> %{"arena_id" => arena_id, "count" => count} end)
    |> Jason.encode!()
  end

  @doc "Decodes `cards_json` back into an entries list of tuples."
  @spec decode_entries(String.t()) :: [entry()]
  def decode_entries(cards_json) when is_binary(cards_json) do
    cards_json
    |> Jason.decode!()
    |> Enum.map(fn %{"arena_id" => arena_id, "count" => count} -> {arena_id, count} end)
  end

  defp normalise_entries(%{entries: entries} = attrs) when is_list(entries) do
    attrs
    |> Map.delete(:entries)
    |> Map.put_new(:cards_json, encode_entries(entries))
    |> Map.put_new(:card_count, length(entries))
    |> Map.put_new(:total_copies, Enum.reduce(entries, 0, fn {_, count}, acc -> acc + count end))
  end

  defp normalise_entries(%{"entries" => entries} = attrs) when is_list(entries) do
    entries_tuples =
      Enum.map(entries, fn
        {k, v} -> {k, v}
        %{"arena_id" => k, "count" => v} -> {k, v}
      end)

    attrs
    |> Map.delete("entries")
    |> Map.put_new("cards_json", encode_entries(entries_tuples))
    |> Map.put_new("card_count", length(entries_tuples))
    |> Map.put_new(
      "total_copies",
      Enum.reduce(entries_tuples, 0, fn {_, count}, acc -> acc + count end)
    )
  end

  defp normalise_entries(attrs), do: attrs
end
