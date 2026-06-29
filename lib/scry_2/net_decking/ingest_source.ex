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
    decks = source_module.fetch()

    {ingested, failed} =
      Enum.reduce(decks, {0, 0}, fn raw_deck, {ok, bad} ->
        case ingest_one(raw_deck) do
          :ok -> {ok + 1, bad}
          :error -> {ok, bad + 1}
        end
      end)

    name = decks |> List.first() |> source_name(source_module)
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

  defp source_name(%{source_name: name}, _module), do: name
  defp source_name(_nil, module), do: inspect(module)
end
