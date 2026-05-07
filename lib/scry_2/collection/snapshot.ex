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

  Mastery-pass fields (`mastery_*`) are also nullable and populated by
  the new mastery walker (`walker/mastery.rs`) on each snapshot when the
  3-hop chain `PAPA → SetMasteryDataProvider → AwsSetMasteryStrategy →
  ProgressionTrack` resolves. Between mastery seasons or when the
  runtime strategy isn't `AwsSetMasteryStrategy`, the walker returns
  `{:ok, nil}` and the columns stay null. See spike 20 for the chain.

  `mtga_player_cards_version` mirrors MTGA's `_playerCardsVersion` i32
  on `InventoryManager` — a monotonic counter that bumps every time
  the player's cards dictionary changes (pack open, draft pick, vault
  open, etc). Stamping it on each snapshot lets the reader detect
  steady-state polls (consecutive snapshots with the same version =
  no card changes) and short-circuit the expensive cards walk.
  Nullable; older walker builds and unreachable chains leave it nil.
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
    :boosters_json,
    :mtga_match_id,
    :match_phase,
    :mastery_tier,
    :mastery_xp_in_tier,
    :mastery_orbs,
    :mastery_season_name,
    :mastery_season_ends_at,
    :cosmetics_json,
    :mtga_player_cards_version
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
    field :boosters_json, :string
    field :mtga_match_id, :string
    field :match_phase, :string
    field :mastery_tier, :integer
    field :mastery_xp_in_tier, :integer
    field :mastery_orbs, :integer
    field :mastery_season_name, :string
    field :mastery_season_ends_at, :utc_datetime
    field :cosmetics_json, :string
    field :mtga_player_cards_version, :integer

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Encodes a list of `%{collation_id, count}` rows as the canonical
  JSON blob for the `boosters_json` column.
  """
  @spec encode_boosters([%{collation_id: integer(), count: integer()}]) :: String.t()
  def encode_boosters(boosters) when is_list(boosters) do
    boosters
    |> Enum.map(fn
      %{collation_id: cid, count: cnt} -> %{"collation_id" => cid, "count" => cnt}
      %{"collation_id" => cid, "count" => cnt} -> %{"collation_id" => cid, "count" => cnt}
    end)
    |> Jason.encode!()
  end

  @doc "Decodes `boosters_json` back into a list of plain `{collation_id, count}` tuples."
  @spec decode_boosters(String.t() | nil) :: [{integer(), integer()}]
  def decode_boosters(nil), do: []
  def decode_boosters("null"), do: []

  def decode_boosters(json) when is_binary(json) do
    json
    |> Jason.decode!()
    |> Enum.map(fn %{"collation_id" => cid, "count" => cnt} -> {cid, cnt} end)
  end

  @doc """
  Encodes the cosmetics summary returned by `MtgaMemory.walk_cosmetics/1`
  as the JSON blob stored in `cosmetics_json`. Accepts either the
  walker's atom-keyed map or a previously-decoded string-keyed map.
  """
  @spec encode_cosmetics(map() | nil) :: String.t() | nil
  def encode_cosmetics(nil), do: nil

  def encode_cosmetics(%{} = summary) do
    summary
    |> normalise_cosmetics_keys()
    |> Jason.encode!()
  end

  @doc """
  Decodes `cosmetics_json` into a map with atom keys for the top-level
  fields and atom-keyed sub-maps for `available` / `owned` / `equipped`.
  Returns `nil` for nil / "null" / unparseable input.
  """
  @spec decode_cosmetics(String.t() | nil) :: map() | nil
  def decode_cosmetics(nil), do: nil
  def decode_cosmetics("null"), do: nil

  def decode_cosmetics(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = decoded} ->
        %{
          available: take_count_keys(decoded["available"] || %{}),
          owned: take_count_keys(decoded["owned"] || %{}),
          equipped: take_equipped_keys(decoded["equipped"] || %{})
        }

      _ ->
        nil
    end
  end

  defp normalise_cosmetics_keys(%{} = summary) do
    %{
      "available" => stringify_count_keys(Map.get(summary, :available, %{})),
      "owned" => stringify_count_keys(Map.get(summary, :owned, %{})),
      "equipped" => stringify_equipped_keys(Map.get(summary, :equipped, %{}))
    }
  end

  defp stringify_count_keys(%{} = counts) do
    %{
      "art_styles" => Map.get(counts, :art_styles, Map.get(counts, "art_styles", 0)) || 0,
      "avatars" => Map.get(counts, :avatars, Map.get(counts, "avatars", 0)) || 0,
      "pets" => Map.get(counts, :pets, Map.get(counts, "pets", 0)) || 0,
      "sleeves" => Map.get(counts, :sleeves, Map.get(counts, "sleeves", 0)) || 0,
      "emotes" => Map.get(counts, :emotes, Map.get(counts, "emotes", 0)) || 0,
      "titles" => Map.get(counts, :titles, Map.get(counts, "titles", 0)) || 0
    }
  end

  defp stringify_equipped_keys(%{} = equipped) do
    %{
      "avatar" => Map.get(equipped, :avatar, Map.get(equipped, "avatar")),
      "card_back" => Map.get(equipped, :card_back, Map.get(equipped, "card_back")),
      "pet" => Map.get(equipped, :pet, Map.get(equipped, "pet")),
      "title" => Map.get(equipped, :title, Map.get(equipped, "title"))
    }
  end

  defp take_count_keys(%{} = counts) do
    %{
      art_styles: Map.get(counts, "art_styles", 0) || 0,
      avatars: Map.get(counts, "avatars", 0) || 0,
      pets: Map.get(counts, "pets", 0) || 0,
      sleeves: Map.get(counts, "sleeves", 0) || 0,
      emotes: Map.get(counts, "emotes", 0) || 0,
      titles: Map.get(counts, "titles", 0) || 0
    }
  end

  defp take_equipped_keys(%{} = equipped) do
    %{
      avatar: Map.get(equipped, "avatar"),
      card_back: Map.get(equipped, "card_back"),
      pet: Map.get(equipped, "pet"),
      title: Map.get(equipped, "title")
    }
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
