defmodule Scry2.Economy.IngestMemoryGrants do
  @moduledoc """
  Subscribes to `Topics.collection_diffs/0`. For each new
  `{:diff_saved, %Collection.Diff{}}`, fetches the two referenced
  snapshots and runs
  `Scry2.Economy.record_memory_grants_from_snapshot_pair/3` to
  detect any card grants the MTGA event log didn't already explain
  (most notably pack-opens) and persist them as
  `economy_card_grants` rows stamped with `source: "MemoryDiff"`.

  Stateless. Mirrors `Scry2.Crafts.IngestCollectionDiffs` — same
  PubSub topic, same `prev/next` snapshot pair, just a different
  attribution rule and projection table.

  v1 does not dedupe against log-driven `CardsGranted` rows. The
  same arena_id arriving via both paths within a diff window
  produces two rows (one with the real MTGA `Source`, one with
  `MemoryDiff`) — that overlap acts as a built-in cross-check for
  v1 and can be tightened in v2 once the real-world overlap volume
  is observed.
  """

  use GenServer

  require Scry2.Log, as: Log

  alias Scry2.Collection.{Diff, Snapshot}
  alias Scry2.Economy
  alias Scry2.Repo
  alias Scry2.Topics

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    Topics.subscribe(Topics.collection_diffs())
    {:ok, %{}}
  end

  @impl true
  def handle_info({:diff_saved, %Diff{} = diff}, state) do
    process_diff(diff)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp process_diff(%Diff{from_snapshot_id: from_id, to_snapshot_id: to_id}) do
    next = Repo.get(Snapshot, to_id)
    prev = from_id && Repo.get(Snapshot, from_id)

    case next do
      nil ->
        Log.warning(:ingester, fn ->
          "memory_grants: to_snapshot #{inspect(to_id)} missing — skipping diff"
        end)

      %Snapshot{} ->
        case Economy.record_memory_grants_from_snapshot_pair(prev, next) do
          {:ok, nil} ->
            :ok

          {:ok, grant} ->
            Log.info(:ingester, fn ->
              "memory_grants: recorded #{grant.card_count} unattributed cards for snapshot #{next.id}"
            end)
        end
    end
  end
end
