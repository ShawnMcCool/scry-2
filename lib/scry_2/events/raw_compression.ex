defmodule Scry2.Events.RawCompression do
  @moduledoc """
  zstd codec for `mtga_logs_events.raw_json` at rest (ADR-042, stage 1a).

  The raw event store is ~80% of the database. Each `GreToClientEvent`
  resends most of the board, so the stream is highly redundant — but rows are
  stored and read independently, so we compress each `raw_json` on its own.
  Measured per-row ratio ~7.7× (zstd-19), taking the 3.24 GB raw store to
  ~440 MB with no semantic change and no data loss.

  ## Plain, self-contained frames

  Each row is an independent zstd frame — no shared dictionary. A dictionary
  would be ~3× leaner but is a single point of failure: lose the one
  dictionary asset and the *entire* raw store becomes undecodable. Plain
  frames keep every row decodable on its own (ADR-042, Q4).

  ## Legacy passthrough

  The table is a mix during/after migration: legacy plaintext rows (written
  before stage 1a) and compressed rows. `decompress/1` tells them apart by
  the zstd magic bytes `0x28 0xB5 0x2F 0xFD`. MTGA `raw_json` always starts
  with `{` (`0x7B`) — never the zstd magic — so plaintext can never be
  mistaken for a frame, and a plaintext row is returned unchanged.

  ## Implementation

  Uses OTP 28's stdlib `:zstd` module — no NIF dependency, builds on every
  platform. Rows written before v0.52.1 by the ezstd NIF are standard zstd
  frames (RFC 8878) and decode identically; a pinned fixture test guards
  that contract.
  """

  # zstd frame magic number (little-endian 0xFD2FB528), the first 4 bytes of
  # every zstd frame. See the zstd format spec (RFC 8878 §3.1.1).
  @zstd_magic <<0x28, 0xB5, 0x2F, 0xFD>>

  # Per-row level. L9→L19 only moved the ratio 7.45×→7.67× (measured), so the
  # extra levels buy little; 19 is the max practical ratio and per-event /
  # one-time-migration cost is immaterial at this app's volumes.
  @level 19

  @doc "Compresses a raw JSON payload into a self-contained zstd frame."
  @spec compress(binary()) :: binary()
  def compress(payload) when is_binary(payload) do
    payload
    |> :zstd.compress(%{compressionLevel: @level})
    |> IO.iodata_to_binary()
  end

  @doc """
  Compresses `payload` unless it is already a zstd frame.

  Idempotent — safe to call at write seams and on re-ingest. Double
  compression would corrupt the row (`decompress/1` only unwraps one frame),
  so this guard is load-bearing, not cosmetic.
  """
  @spec ensure_compressed(binary()) :: binary()
  def ensure_compressed(@zstd_magic <> _rest = frame), do: frame
  def ensure_compressed(payload) when is_binary(payload), do: compress(payload)

  @doc """
  Returns the original payload, decompressing zstd frames and passing legacy
  plaintext through unchanged.
  """
  @spec decompress(binary()) :: binary()
  def decompress(@zstd_magic <> _rest = frame),
    do: frame |> :zstd.decompress() |> IO.iodata_to_binary()

  def decompress(plaintext) when is_binary(plaintext), do: plaintext

  @doc "True when `data` is a zstd frame (vs legacy plaintext)."
  @spec compressed?(binary()) :: boolean()
  def compressed?(@zstd_magic <> _rest), do: true
  def compressed?(data) when is_binary(data), do: false
end
