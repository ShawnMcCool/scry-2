defmodule Scry2.MtgaLogIngestion.RawCompressionBackfill do
  @moduledoc """
  One-time, resumable backfill that zstd-compresses legacy plaintext
  `raw_json` rows in `mtga_logs_events` (ADR-042 stage 1a).

  **Deliberately NOT a migration.** Migrations auto-run at startup; rewriting
  the multi-GB raw store must be an explicit, backed-up operation, never a
  side effect of a restart. Run it by hand from a remote shell against the
  live instance — same BEAM, same `Repo`, so no second SQLite writer:

      # back up scry_2.db first
      iex> Scry2.MtgaLogIngestion.RawCompressionBackfill.run()
      %{scanned: 704971, compressed: 704971, bytes_before: ..., bytes_after: ...}

  Idempotent and resumable: already-compressed rows are skipped via the zstd
  magic-byte check (`RawCompression.compressed?/1`), so re-running after an
  interruption simply continues. No row is ever deleted.

  Pass `progress_every: n` to control the log cadence (default 50 batches).

  ## Reclaiming disk

  Compression rewrites payloads in place but SQLite does NOT shrink the file
  on UPDATE — freed pages stay in the file. After the backfill, run `VACUUM`
  to actually reclaim disk (needs free space ~= the final DB size, and an
  exclusive lock, so do it with the instance stopped). Measured full-store
  reclaim is ~8.3× (raw store 3.24 GB of payload -> ~390 MB).
  """

  import Ecto.Query
  require Scry2.Log, as: Log

  alias Scry2.Events.RawCompression
  alias Scry2.MtgaLogIngestion.EventRecord
  alias Scry2.Repo

  @type stats :: %{
          scanned: non_neg_integer(),
          compressed: non_neg_integer(),
          bytes_before: non_neg_integer(),
          bytes_after: non_neg_integer()
        }

  @doc "Compresses every legacy plaintext raw_json row. See the moduledoc."
  @spec run(keyword()) :: stats()
  def run(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 1000)
    progress_every = Keyword.get(opts, :progress_every, 50)

    Log.info(:importer, "raw compression backfill: starting (batch_size=#{batch_size})")
    stats = %{scanned: 0, compressed: 0, bytes_before: 0, bytes_after: 0}
    result = loop(0, batch_size, progress_every, 0, stats)

    Log.info(
      :importer,
      "raw compression backfill: done — scanned=#{result.scanned} " <>
        "compressed=#{result.compressed} " <>
        "bytes #{result.bytes_before}->#{result.bytes_after}"
    )

    result
  end

  defp loop(after_id, batch_size, progress_every, batch_num, stats) do
    rows =
      from(r in EventRecord,
        where: r.id > ^after_id,
        order_by: [asc: r.id],
        limit: ^batch_size,
        select: %{id: r.id, raw_json: r.raw_json}
      )
      |> Repo.all()

    case rows do
      [] ->
        stats

      _ ->
        stats = Enum.reduce(rows, stats, &compress_row/2)

        if rem(batch_num, progress_every) == 0 do
          Log.info(
            :importer,
            "raw compression backfill: scanned=#{stats.scanned} compressed=#{stats.compressed}"
          )
        end

        last_id = rows |> List.last() |> Map.fetch!(:id)
        loop(last_id, batch_size, progress_every, batch_num + 1, stats)
    end
  end

  defp compress_row(%{id: id, raw_json: raw_json}, stats) do
    stats = Map.update!(stats, :scanned, &(&1 + 1))

    if RawCompression.compressed?(raw_json) do
      add_bytes(stats, byte_size(raw_json), byte_size(raw_json))
    else
      frame = RawCompression.compress(raw_json)
      {1, _} = Repo.update_all(from(r in EventRecord, where: r.id == ^id), set: [raw_json: frame])

      stats
      |> Map.update!(:compressed, &(&1 + 1))
      |> add_bytes(byte_size(raw_json), byte_size(frame))
    end
  end

  defp add_bytes(stats, before_bytes, after_bytes) do
    stats
    |> Map.update!(:bytes_before, &(&1 + before_bytes))
    |> Map.update!(:bytes_after, &(&1 + after_bytes))
  end
end
