defmodule Scry2.MatchEconomy.Capture do
  @moduledoc """
  Side-effecting work spawned by `Trigger`: synchronously reads MTGA
  memory, persists tagged `Collection.Snapshot` rows, upserts
  `MatchEconomy.Summary` rows with computed deltas + log reconciliation,
  and broadcasts on `Topics.match_economy_updates/0`.

  This is a plain module — no GenServer, no state. Every function runs
  inside the Task body that `Trigger` spawns, so it executes in a fresh
  process that already holds sandbox ownership in tests.
  """

  require Scry2.Log, as: Log

  alias Scry2.Collection
  alias Scry2.Collection.Reader
  alias Scry2.Events.Match.{MatchCompleted, MatchCreated}
  alias Scry2.MatchEconomy
  alias Scry2.MatchEconomy.{AggregateLog, Compute}
  alias Scry2.Repo
  alias Scry2.Topics

  @doc """
  Called on `MatchCreated`. Reads memory, persists a pre-match snapshot
  tagged with `match_phase: "pre"`, and inserts an incomplete summary row.
  """
  @spec handle_match_created(MatchCreated.t()) :: :ok
  def handle_match_created(%MatchCreated{} = event) do
    pre_snapshot_id =
      case Reader.read([]) do
        {:ok, result} ->
          result
          |> Map.put(:mtga_match_id, event.mtga_match_id)
          |> Map.put(:match_phase, "pre")
          |> Collection.save_snapshot()
          |> case do
            {:ok, snapshot} ->
              snapshot.id

            {:error, changeset} ->
              Log.warning(:system, "match_economy pre-snapshot failed: #{inspect(changeset)}")
              nil
          end

        {:error, reason} ->
          Log.warning(:system, "match_economy pre-read failed: #{inspect(reason)}")
          nil
      end

    summary =
      MatchEconomy.upsert_summary!(%{
        mtga_match_id: event.mtga_match_id,
        started_at: event.occurred_at,
        pre_snapshot_id: pre_snapshot_id,
        reconciliation_state: "incomplete"
      })

    Topics.broadcast(Topics.match_economy_updates(), {:match_economy_updated, summary})
    :ok
  end

  @doc """
  Called on `MatchCompleted`. Reads memory, persists a post-match snapshot
  tagged with `match_phase: "post"`, computes memory + log deltas, and
  upserts the summary to `"complete"` (or `"log_only"` when snapshots
  are unavailable).
  """
  @spec handle_match_completed(MatchCompleted.t()) :: :ok
  def handle_match_completed(%MatchCompleted{} = event) do
    post_snapshot_id =
      case Reader.read([]) do
        {:ok, result} ->
          result
          |> Map.put(:mtga_match_id, event.mtga_match_id)
          |> Map.put(:match_phase, "post")
          |> Collection.save_snapshot()
          |> case do
            {:ok, snapshot} ->
              snapshot.id

            {:error, changeset} ->
              Log.warning(:system, "match_economy post-snapshot failed: #{inspect(changeset)}")
              nil
          end

        {:error, reason} ->
          Log.warning(:system, "match_economy post-read failed: #{inspect(reason)}")
          nil
      end

    existing = MatchEconomy.get_summary(event.mtga_match_id)
    pre_snapshot_id = existing && existing.pre_snapshot_id
    started_at = existing && existing.started_at
    ended_at = event.occurred_at

    pre = if pre_snapshot_id, do: Repo.get(Collection.Snapshot, pre_snapshot_id), else: nil
    post = if post_snapshot_id, do: Repo.get(Collection.Snapshot, post_snapshot_id), else: nil

    window? = not is_nil(started_at) and not is_nil(ended_at)

    memory =
      if pre && post,
        do: Compute.memory_deltas(pre, post),
        else: Compute.memory_deltas(nil, nil)

    log =
      if window? do
        AggregateLog.over(started_at, ended_at)
      else
        %{
          gold: nil,
          gems: nil,
          wildcards_common: nil,
          wildcards_uncommon: nil,
          wildcards_rare: nil,
          wildcards_mythic: nil
        }
      end

    diffs = Compute.diffs(memory, log)
    state = Compute.reconciliation_state(pre, post, window?)

    summary =
      MatchEconomy.upsert_summary!(%{
        mtga_match_id: event.mtga_match_id,
        started_at: started_at,
        ended_at: ended_at,
        pre_snapshot_id: pre_snapshot_id,
        post_snapshot_id: post_snapshot_id,
        memory_gold_delta: memory.gold,
        memory_gems_delta: memory.gems,
        memory_wildcards_common_delta: memory.wildcards_common,
        memory_wildcards_uncommon_delta: memory.wildcards_uncommon,
        memory_wildcards_rare_delta: memory.wildcards_rare,
        memory_wildcards_mythic_delta: memory.wildcards_mythic,
        memory_vault_delta: memory.vault,
        log_gold_delta: log.gold,
        log_gems_delta: log.gems,
        log_wildcards_common_delta: log.wildcards_common,
        log_wildcards_uncommon_delta: log.wildcards_uncommon,
        log_wildcards_rare_delta: log.wildcards_rare,
        log_wildcards_mythic_delta: log.wildcards_mythic,
        diff_gold: diffs.gold,
        diff_gems: diffs.gems,
        diff_wildcards_common: diffs.wildcards_common,
        diff_wildcards_uncommon: diffs.wildcards_uncommon,
        diff_wildcards_rare: diffs.wildcards_rare,
        diff_wildcards_mythic: diffs.wildcards_mythic,
        reconciliation_state: state
      })

    Topics.broadcast(Topics.match_economy_updates(), {:match_economy_updated, summary})
    :ok
  end
end
