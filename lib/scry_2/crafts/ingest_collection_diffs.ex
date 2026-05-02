defmodule Scry2.Crafts.IngestCollectionDiffs do
  @moduledoc """
  Subscribes to `Topics.collection_diffs/0`. For each new
  `{:diff_saved, %Collection.Diff{}}`, fetches the two referenced
  snapshots and runs `Scry2.Crafts.record_from_snapshot_pair/2` to
  detect and persist any wildcard crafts (ADR-037).

  Stateless. No catch-up on init — historical backfill goes through
  `Scry2.Crafts.replay!/0`. Mirrors the shape of
  `Scry2.Events.IngestRawEvents` but with much smaller scope: there
  is no domain-event log to keep, no self-user state to remember.
  """

  use GenServer

  require Scry2.Log, as: Log

  alias Scry2.Collection.{Diff, Snapshot}
  alias Scry2.Crafts
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
          "crafts: to_snapshot #{inspect(to_id)} missing — skipping diff"
        end)

      %Snapshot{} ->
        case Crafts.record_from_snapshot_pair(prev, next) do
          {:ok, []} ->
            :ok

          {:ok, crafts} ->
            Log.info(:ingester, fn ->
              "crafts: recorded #{length(crafts)} for snapshot #{next.id}"
            end)
        end
    end
  end
end
