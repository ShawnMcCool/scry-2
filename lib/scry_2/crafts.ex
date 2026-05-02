defmodule Scry2.Crafts do
  @moduledoc """
  Public facade for the wildcard craft attribution subsystem (ADR-037).

  Owns the `crafts` table — one row per detected wildcard spend, derived
  from a pair of consecutive `Scry2.Collection.Snapshot` rows.

  Pipeline:

      collection_snapshots               (owned by Collection)
        → Collection.SnapshotDiff
          → broadcasts {:diff_saved, _} on collection:diffs
            → Crafts.IngestCollectionDiffs (subscriber)
              → AttributeCrafts.attribute/3 (pure)
                → Crafts.record_from_snapshot_pair/2
                  → broadcasts {:crafts_recorded, _} on crafts:updates

  v1 attributes only clean single-card windows — see ADR-037 for the
  rule and the rationale for skipping contested windows. Replay over
  historical snapshots is idempotent via the
  `(to_snapshot_id, arena_id)` unique index.

  Communicates:
    * Subscribes — `Topics.collection_diffs/0` (via
      `Crafts.IngestCollectionDiffs`).
    * Broadcasts — `Topics.crafts_updates/0`
      (`{:crafts_recorded, [%Craft{}]}`).
  """

  import Ecto.Query

  alias Scry2.Cards
  alias Scry2.Collection.Snapshot
  alias Scry2.Crafts.{AttributeCrafts, Attribution, Craft}
  alias Scry2.Repo
  alias Scry2.Topics

  @doc """
  Returns the most recent crafts, newest-first by `occurred_at_upper`.

  Options:
    * `:limit` — cap on rows returned (default 50).
  """
  @spec list_recent(keyword()) :: [Craft.t()]
  def list_recent(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Craft
    |> order_by([c], desc: c.occurred_at_upper, desc: c.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Total number of `Craft` rows persisted."
  @spec count() :: non_neg_integer()
  def count, do: Repo.aggregate(Craft, :count, :id)

  @doc """
  Runs attribution for one snapshot pair and persists detected crafts.

  Returns `{:ok, [%Craft{}]}` on success — possibly an empty list if
  the pair produced no attributions or all detected crafts were
  already recorded. Broadcasts on `Topics.crafts_updates/0` only when
  rows were actually inserted (empty batches do not broadcast).

  Idempotent: re-running on the same pair upserts nothing new
  (`(to_snapshot_id, arena_id)` unique index, `on_conflict: :nothing`).
  """
  @spec record_from_snapshot_pair(Snapshot.t() | nil, Snapshot.t()) ::
          {:ok, [Craft.t()]}
  def record_from_snapshot_pair(prev, %Snapshot{} = next) do
    case AttributeCrafts.attribute(prev, next, rarities_for(prev, next)) do
      [] ->
        {:ok, []}

      attributions ->
        persist_attributions(attributions, prev, next)
    end
  end

  @doc """
  Re-runs attribution over every consecutive snapshot pair in
  `collection_snapshots`, persisting any newly-attributable crafts.
  Idempotent — already-recorded crafts are skipped via the unique
  index. Used for backfill on first deploy and after rule changes.

  Returns a summary `%{processed: n_pairs, recorded: n_new_crafts}`.
  """
  @spec replay!() :: %{processed: non_neg_integer(), recorded: non_neg_integer()}
  def replay! do
    snapshots =
      Snapshot
      |> order_by([s], asc: s.snapshot_ts, asc: s.id)
      |> Repo.all()

    {recorded, _, processed} =
      Enum.reduce(snapshots, {0, nil, 0}, fn snap, {recorded_count, prev, processed_count} ->
        case record_from_snapshot_pair(prev, snap) do
          {:ok, crafts} -> {recorded_count + length(crafts), snap, processed_count + 1}
        end
      end)

    %{processed: processed, recorded: recorded}
  end

  # ── Internals ────────────────────────────────────────────────────────────

  defp persist_attributions(attributions, prev, next) do
    now = DateTime.utc_now()

    rows =
      Enum.map(attributions, fn %Attribution{} = a ->
        %{
          occurred_at_lower: occurred_lower(prev, next),
          occurred_at_upper: next.snapshot_ts,
          arena_id: a.arena_id,
          rarity: Atom.to_string(a.rarity),
          quantity: a.quantity,
          from_snapshot_id: prev && prev.id,
          to_snapshot_id: next.id,
          inserted_at: now,
          updated_at: now
        }
      end)

    {inserted, _} =
      Repo.insert_all(Craft, rows,
        on_conflict: :nothing,
        conflict_target: [:to_snapshot_id, :arena_id]
      )

    if inserted > 0 do
      crafts = list_for_snapshot(next.id)
      Topics.broadcast(Topics.crafts_updates(), {:crafts_recorded, crafts})
      {:ok, crafts}
    else
      {:ok, []}
    end
  end

  defp list_for_snapshot(snapshot_id) do
    Craft
    |> where([c], c.to_snapshot_id == ^snapshot_id)
    |> order_by([c], asc: c.id)
    |> Repo.all()
  end

  defp occurred_lower(nil, next), do: next.snapshot_ts
  defp occurred_lower(prev, _next), do: prev.snapshot_ts

  defp rarities_for(prev, next) do
    case changed_arena_ids(prev, next) do
      [] ->
        %{}

      arena_ids ->
        arena_ids
        |> Cards.list_by_arena_ids()
        |> Enum.into(%{}, fn {arena_id, card_or_map} ->
          {arena_id, extract_rarity(card_or_map)}
        end)
        |> Map.reject(fn {_id, rarity} -> is_nil(rarity) end)
    end
  end

  defp changed_arena_ids(nil, next), do: arena_ids_of(next)

  defp changed_arena_ids(prev, next) do
    (arena_ids_of(prev) ++ arena_ids_of(next)) |> Enum.uniq()
  end

  defp arena_ids_of(%Snapshot{cards_json: nil}), do: []

  defp arena_ids_of(%Snapshot{cards_json: json}) when is_binary(json) do
    json
    |> Snapshot.decode_entries()
    |> Enum.map(fn {arena_id, _count} -> arena_id end)
  end

  defp extract_rarity(%Cards.Card{rarity: rarity}), do: normalise_rarity(rarity)
  defp extract_rarity(_), do: nil

  defp normalise_rarity("common"), do: :common
  defp normalise_rarity("uncommon"), do: :uncommon
  defp normalise_rarity("rare"), do: :rare
  defp normalise_rarity("mythic"), do: :mythic
  defp normalise_rarity(_), do: nil
end
