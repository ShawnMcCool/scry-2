defmodule Scry2.Collection do
  @moduledoc """
  Public facade for the memory-read card collection subsystem (ADR 034).

  Owns:
    * `collection_snapshots` table (append-only capture log).
    * `collection_diffs` table (per-card delta between consecutive
      snapshots — the acquisition ledger, since `Player.log` no longer
      carries per-card grant events).
    * The `collection.reader_enabled` settings flag.

  Communicates:
    * Subscribes — none (divergence checks read `mtga_logs_*` schemas
      directly when they land).
    * Broadcasts —
      `Scry2.Topics.collection_snapshots/0` (`{:snapshot_saved, _}`),
      `Scry2.Topics.collection_diffs/0` (`{:diff_saved, _}`).

  The actual memory read lives in `Scry2.Collection.Reader`; the Oban
  worker `Scry2.Collection.RefreshJob` drives scheduled and manual
  refreshes. Diff computation is pure
  (`Scry2.Collection.SnapshotDiff.diff/2`) and persisted in the same
  transaction as the snapshot.
  """

  alias Ecto.Multi
  alias Scry2.Collection.BuildChange
  alias Scry2.Collection.Diff
  alias Scry2.Collection.RefreshJob
  alias Scry2.Collection.Snapshot
  alias Scry2.Collection.SnapshotDiff
  alias Scry2.Repo
  alias Scry2.Settings
  alias Scry2.Topics
  alias Scry2.Version

  import Ecto.Query

  @reader_enabled_key "collection.reader_enabled"
  @acknowledged_build_hint_key "collection.acknowledged_build_hint"

  @doc "Returns the most recent collection snapshot, or `nil`."
  @spec current() :: Snapshot.t() | nil
  def current do
    Snapshot
    |> order_by([s], desc: s.snapshot_ts)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Returns snapshots newest-first.

  Options:
    * `:limit` — cap on rows returned (default 50).
  """
  @spec list_snapshots(keyword()) :: [Snapshot.t()]
  def list_snapshots(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Snapshot
    |> order_by([s], desc: s.snapshot_ts)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Returns true if the memory reader is user-enabled."
  @spec reader_enabled?() :: boolean()
  def reader_enabled? do
    Settings.get(@reader_enabled_key, false) == true
  end

  @doc "Enables the memory reader (user has signed the consent modal)."
  @spec enable_reader!() :: :ok
  def enable_reader! do
    Settings.put!(@reader_enabled_key, true)
    :ok
  end

  @doc "Disables the memory reader — kill switch (ADR 034)."
  @spec disable_reader!() :: :ok
  def disable_reader! do
    Settings.put!(@reader_enabled_key, false)
    :ok
  end

  @doc """
  Enqueues a `RefreshJob`. `trigger` classifies the origin so the UI
  can distinguish manual vs scheduled runs in the snapshot log.
  """
  @spec refresh(keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def refresh(opts \\ []) do
    trigger = Keyword.get(opts, :trigger, "manual")
    %{"trigger" => to_string(trigger)} |> RefreshJob.new() |> Oban.insert()
  end

  @doc """
  Persists a read result as a `Snapshot` row plus, if a previous
  snapshot exists, a `Diff` row capturing the per-card delta. Both
  inserts happen in a single transaction.

  Broadcasts:
    * `{:snapshot_saved, snapshot}` on `Topics.collection_snapshots/0`
    * `{:diff_saved, diff}` on `Topics.collection_diffs/0` — only when
      a diff was actually computed (i.e. there was a prior snapshot).

  Accepts the map returned by `Scry2.Collection.Reader.read/1`.
  """
  @spec save_snapshot(%{
          :entries => [Snapshot.entry()],
          :card_count => non_neg_integer(),
          :total_copies => non_neg_integer(),
          :reader_confidence => String.t(),
          optional(atom()) => term()
        }) :: {:ok, Snapshot.t()} | {:error, Ecto.Changeset.t()}
  def save_snapshot(result) do
    attrs =
      %{
        snapshot_ts: DateTime.utc_now(),
        reader_version: Version.current(),
        reader_confidence: result.reader_confidence,
        card_count: result.card_count,
        total_copies: result.total_copies,
        entries: result.entries
      }
      |> Map.merge(walker_fields(result))
      |> Map.merge(match_tag_fields(result))
      |> Map.merge(mastery_fields(result))

    snapshot_changeset = Snapshot.changeset(%Snapshot{}, attrs)
    previous = current()

    multi =
      Multi.new()
      |> Multi.insert(:snapshot, snapshot_changeset)
      |> Multi.insert(:diff, fn %{snapshot: snapshot} ->
        delta = SnapshotDiff.diff(previous, snapshot)
        totals = SnapshotDiff.totals(delta)

        Diff.changeset(%Diff{}, %{
          from_snapshot_id: previous && previous.id,
          to_snapshot_id: snapshot.id,
          acquired: delta.acquired,
          removed: delta.removed,
          total_acquired: totals.total_acquired,
          total_removed: totals.total_removed
        })
      end)

    case Repo.transaction(multi) do
      {:ok, %{snapshot: snapshot, diff: diff}} ->
        maybe_auto_acknowledge_first_build_hint(snapshot)
        Topics.broadcast(Topics.collection_snapshots(), {:snapshot_saved, snapshot})
        Topics.broadcast(Topics.collection_diffs(), {:diff_saved, diff})
        {:ok, snapshot}

      {:error, _step, changeset, _changes} ->
        {:error, changeset}
    end
  end

  @doc """
  The MTGA build the user has acknowledged as known-good for the
  memory reader. `nil` means no acknowledgement has been made yet.
  """
  @spec acknowledged_build_hint() :: String.t() | nil
  def acknowledged_build_hint do
    Settings.get(@acknowledged_build_hint_key)
  end

  @doc """
  Acknowledge the build_hint stamped on the most recent snapshot.
  Use after the user has verified that the memory reader is still
  returning correct data following an MTGA update.

  Returns `:no_data` when there is no walker snapshot to acknowledge.
  """
  @spec acknowledge_current_build!() :: :ok | :no_data
  def acknowledge_current_build! do
    case current_build_hint() do
      nil ->
        :no_data

      hint ->
        Settings.put!(@acknowledged_build_hint_key, hint)
        :ok
    end
  end

  @doc """
  Compare the latest snapshot's `mtga_build_hint` against the
  acknowledged value. See `Scry2.Collection.BuildChange.detect/2` for
  the result type.
  """
  @spec build_change_status() :: BuildChange.t()
  def build_change_status do
    BuildChange.detect(acknowledged_build_hint(), current_build_hint())
  end

  defp current_build_hint do
    case current() do
      %Snapshot{mtga_build_hint: hint} -> hint
      _ -> nil
    end
  end

  defp maybe_auto_acknowledge_first_build_hint(%Snapshot{mtga_build_hint: nil}), do: :ok

  defp maybe_auto_acknowledge_first_build_hint(%Snapshot{mtga_build_hint: hint})
       when is_binary(hint) do
    if is_nil(acknowledged_build_hint()) do
      Settings.put!(@acknowledged_build_hint_key, hint)
    end

    :ok
  end

  @doc "Returns the most recent diff, or `nil` if none exist yet."
  @spec latest_diff() :: Diff.t() | nil
  def latest_diff do
    Diff
    |> order_by([d], desc: d.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Returns diffs newest-first.

  Options:
    * `:limit` — cap on rows returned (default 50).
  """
  @spec list_diffs(keyword()) :: [Diff.t()]
  def list_diffs(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Diff
    |> order_by([d], desc: d.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Computes the diff between two snapshot ids on demand. Returns `nil`
  if either snapshot is missing. Does not persist anything.
  """
  @spec diff_between(integer(), integer()) :: SnapshotDiff.t() | nil
  def diff_between(from_id, to_id) when is_integer(from_id) and is_integer(to_id) do
    case {Repo.get(Snapshot, from_id), Repo.get(Snapshot, to_id)} do
      {nil, _} -> nil
      {_, nil} -> nil
      {from, to} -> SnapshotDiff.diff(from, to)
    end
  end

  @doc "Total number of `Snapshot` rows persisted."
  @spec count_snapshots() :: non_neg_integer()
  def count_snapshots, do: Repo.aggregate(Snapshot, :count, :id)

  @doc "Total number of `Diff` rows persisted."
  @spec count_diffs() :: non_neg_integer()
  def count_diffs, do: Repo.aggregate(Diff, :count, :id)

  @doc """
  Number of diffs where neither side recorded a change. High empty-diff
  ratio = the reader is being polled more often than the collection
  changes. Used by the diagnostics page as a noise/signal indicator.
  """
  @spec count_empty_diffs() :: non_neg_integer()
  def count_empty_diffs do
    Diff
    |> where([d], d.total_acquired == 0 and d.total_removed == 0)
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Returns the `n` largest diffs by `total_acquired`, newest-first within
  ties. Useful for spotting set releases, vault opens, big draft pools.
  """
  @spec top_diffs_by_acquired(pos_integer()) :: [Diff.t()]
  def top_diffs_by_acquired(n \\ 5) when is_integer(n) and n > 0 do
    Diff
    |> order_by([d], desc: d.total_acquired, desc: d.inserted_at)
    |> limit(^n)
    |> Repo.all()
  end

  @doc """
  Counts snapshots grouped by `reader_confidence` (`"walker"` or
  `"fallback_scan"`). Returns `%{walker: n, fallback_scan: m}` with
  zero defaults so the UI can render percentages safely.
  """
  @spec reader_path_breakdown() :: %{walker: non_neg_integer(), fallback_scan: non_neg_integer()}
  def reader_path_breakdown do
    counts =
      Snapshot
      |> group_by([s], s.reader_confidence)
      |> select([s], {s.reader_confidence, count(s.id)})
      |> Repo.all()
      |> Map.new()

    %{
      walker: Map.get(counts, "walker", 0),
      fallback_scan: Map.get(counts, "fallback_scan", 0)
    }
  end

  defp walker_fields(result) do
    result
    |> Map.take([
      :mtga_build_hint,
      :wildcards_common,
      :wildcards_uncommon,
      :wildcards_rare,
      :wildcards_mythic,
      :gold,
      :gems,
      :vault_progress,
      :boosters_json,
      :cosmetics_json
    ])
  end

  defp match_tag_fields(%{mtga_match_id: id, match_phase: phase})
       when not is_nil(id) and not is_nil(phase) do
    %{mtga_match_id: id, match_phase: phase}
  end

  defp match_tag_fields(_), do: %{}

  defp mastery_fields(result) do
    Map.take(result, [
      :mastery_tier,
      :mastery_xp_in_tier,
      :mastery_orbs,
      :mastery_season_name,
      :mastery_season_ends_at
    ])
  end
end
