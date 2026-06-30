defmodule Scry2.Events.RawPayload do
  @moduledoc """
  Process-local cache for the decoded MTGA raw event payload — decompresses
  the stored `raw_json` (zstd frame or legacy plaintext, ADR-042) then
  `Jason.decode/1`s it.

  Both `Scry2.Events.IngestRawEvents` (gameObjects/rank capture) and
  `Scry2.Events.IdentifyDomainEvents` (translation clauses) need to look
  at the decoded payload of the same record. Without a cache they each
  parse the raw JSON independently — for a `GreToClientEvent` (~5 KB
  average payload, the bulk of the event stream) that's ~50% wasted work
  per event.

  The cache is keyed by record id and lives in the calling process's
  process dictionary, scoped to a single `process_raw_event/3` invocation.
  Errors are not cached so a transient decode failure doesn't poison
  later attempts (those are rare and logged as warnings anyway).

  Always call `forget/1` after the record is fully processed to keep the
  dictionary bounded — a long-lived ingester process would otherwise
  accumulate one cached payload per event ever processed.
  """

  alias Scry2.Events.RawCompression

  @prefix __MODULE__

  @doc """
  Returns `{:ok, payload}` or `{:error, reason}` for `record.raw_json`,
  decoding once per record id per process.
  """
  @spec decode(map()) :: {:ok, term()} | {:error, term()}
  def decode(%{id: id, raw_json: raw_json}) when is_integer(id) do
    cache_key = {@prefix, id}

    case Process.get(cache_key) do
      nil ->
        result = Jason.decode(RawCompression.decompress(raw_json))
        if match?({:ok, _}, result), do: Process.put(cache_key, result)
        result

      cached ->
        cached
    end
  end

  def decode(%{raw_json: raw_json}), do: Jason.decode(RawCompression.decompress(raw_json))

  @doc "Drops the cached payload for `id` from the process dictionary."
  @spec forget(integer()) :: :ok
  def forget(id) when is_integer(id) do
    Process.delete({@prefix, id})
    :ok
  end
end
