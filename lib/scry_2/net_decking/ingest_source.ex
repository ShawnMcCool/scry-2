defmodule Scry2.NetDecking.IngestSource do
  @moduledoc """
  Runs one `Scry2.NetDecking.Source` and pipes every `raw_deck` through
  `Scry2.NetDecking.IngestDecklist.run/1` — the shared Parse→Resolve→Dedup→
  Persist funnel that also serves manual paste.

  A single deck that fails to ingest is logged and skipped; it never aborts the
  rest of the source's decks. Returns `%{source, ingested, failed}`.
  """
  alias Scry2.NetDecking.IngestDecklist

  require Scry2.Log, as: Log

  @spec run(module()) :: %{
          source: String.t(),
          ingested: non_neg_integer(),
          failed: non_neg_integer()
        }
  def run(source_module) when is_atom(source_module) do
    ingest_all(source_module.source_name(), source_module.fetch())
  end

  @doc """
  Fetches one browsable event by URL from a source and runs its decks through
  the funnel. The import-browser path: same stamping and funnel as `run/1`,
  scoped to a single chosen event. A failed fetch propagates as `{:error,
  reason}` so the browser can show it inline.
  """
  @spec run_event(module(), String.t()) ::
          {:ok, %{source: String.t(), ingested: non_neg_integer(), failed: non_neg_integer()}}
          | {:error, term()}
  def run_event(source_module, event_url) when is_atom(source_module) do
    with {:ok, raw_decks} <- source_module.fetch_event(event_url) do
      {:ok, ingest_all(source_module.source_name(), raw_decks)}
    end
  end

  defp ingest_all(name, raw_decks) do
    {ingested, failed} =
      Enum.reduce(raw_decks, {0, 0}, fn raw_deck, {ok, bad} ->
        case ingest_one(Map.put(raw_deck, :source_name, name)) do
          :ok -> {ok + 1, bad}
          :error -> {ok, bad + 1}
        end
      end)

    Log.info(:importer, "netdeck source #{name}: #{ingested} ingested, #{failed} failed")
    %{source: name, ingested: ingested, failed: failed}
  end

  defp ingest_one(raw_deck) do
    case IngestDecklist.run(raw_deck) do
      {:ok, _deck} ->
        :ok

      {:error, reason} ->
        Log.warning(
          :importer,
          "netdeck deck #{inspect(raw_deck[:name])} failed: #{inspect(reason)}"
        )

        :error
    end
  end
end
