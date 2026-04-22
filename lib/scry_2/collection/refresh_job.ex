defmodule Scry2.Collection.RefreshJob do
  @moduledoc """
  Oban worker that runs one memory-read refresh of the MTGA collection.

  Checks the `collection.reader_enabled` settings flag first so the
  user's kill switch is honoured; calls `Scry2.Collection.Reader.read/1`
  through the configured Mem backend; persists the result as a
  `Scry2.Collection.Snapshot` via `Scry2.Collection.save_snapshot/1`.

  Non-fatal errors (MTGA not running, self-check failure, no cards
  array found) are returned as `{:discard, reason}` — Oban will record
  the failure without retrying, since the next manual or cron-scheduled
  run will try again on fresh conditions.

  Fatal errors (DB insert failure, unexpected exception) bubble up so
  Oban retries with backoff.
  """

  use Oban.Worker,
    queue: :collection,
    max_attempts: 3,
    unique: [period: 30, fields: [:worker, :args], states: [:available, :scheduled, :executing]]

  require Scry2.Log, as: Log

  alias Scry2.Collection
  alias Scry2.Collection.Reader
  alias Scry2.Topics

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    trigger = Map.get(args, "trigger", "unknown")

    cond do
      not Collection.reader_enabled?() ->
        Log.info(:system, "collection refresh skipped — reader disabled (trigger=#{trigger})")
        {:discard, :reader_disabled}

      true ->
        Log.info(:system, "collection refresh starting (trigger=#{trigger})")
        run_refresh(trigger)
    end
  end

  defp run_refresh(trigger) do
    reader_opts = Application.get_env(:scry_2, :collection_reader_opts, [])

    case Reader.read(reader_opts) do
      {:ok, result} ->
        case Collection.save_snapshot(result) do
          {:ok, snapshot} ->
            Log.info(:system, fn ->
              "collection refresh ok (trigger=#{trigger} cards=#{snapshot.card_count}" <>
                " copies=#{snapshot.total_copies})"
            end)

            :ok

          {:error, changeset} ->
            # Schema validation failed — escalate (something's off in
            # the Reader result shape). Oban will retry.
            Log.error(:system, fn ->
              "collection snapshot insert failed: #{inspect(changeset)}"
            end)

            {:error, {:persist_failed, changeset}}
        end

      {:error, reason} = err ->
        Log.warning(:system, fn ->
          "collection refresh failed (trigger=#{trigger}): #{inspect(reason)}"
        end)

        Topics.broadcast(Topics.collection_snapshots(), {:refresh_failed, reason})
        {:discard, err}
    end
  end
end
