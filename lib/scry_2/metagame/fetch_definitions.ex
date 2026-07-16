defmodule Scry2.Metagame.FetchDefinitions do
  @moduledoc """
  Upstream refresh: MTGOFormatData repo tarball → parsed definition rows
  → `Scry2.Metagame.replace_definitions!/2`.

  One HTTP request fetches the whole repo archive; `Formats/Standard/`
  entries are extracted in memory and parsed via `ParseDefinitions`.
  Malformed files are skipped with a logged warning — one bad archetype
  must not block the format. A fetch that yields zero archetype
  definitions is rejected outright so a truncated download can never
  wipe the stored vocabulary.
  """

  alias Scry2.Metagame
  alias Scry2.Metagame.ParseDefinitions

  require Scry2.Log, as: Log

  @url "https://github.com/Badaro/MTGOFormatData/archive/refs/heads/main.tar.gz"
  @format "Standard"

  @spec run(keyword()) :: {:ok, :updated | :unchanged} | {:error, term()}
  def run(opts \\ []) do
    req_options = Keyword.get(opts, :req_options, [])

    with {:ok, tarball} <- download(req_options),
         {:ok, files} <- extract(tarball) do
      apply_files(files)
    end
  end

  defp download(req_options) do
    request = Keyword.merge([url: @url, decode_body: false], req_options)

    case Req.get(request) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract(tarball) do
    case :erl_tar.extract({:binary, tarball}, [:memory, :compressed]) do
      {:ok, entries} -> {:ok, format_files(entries)}
      {:error, reason} -> {:error, {:tar, reason}}
    end
  end

  # "MTGOFormatData-main/Formats/Standard/Archetypes/X.json" → "Archetypes/X.json"
  defp format_files(entries) do
    for {path_charlist, content} <- entries,
        path = List.to_string(path_charlist),
        [_prefix, relative] <- [String.split(path, "/Formats/#{@format}/", parts: 2)],
        into: %{} do
      {relative, content}
    end
  end

  defp apply_files(files) do
    parsed = ParseDefinitions.rows_from_files(files)

    Enum.each(parsed.errors, fn {path, reason} ->
      Log.warning(:importer, "metagame: skipped definition file #{path}: #{inspect(reason)}")
    end)

    if not Enum.any?(parsed.definitions, &(&1.kind == "archetype")) do
      {:error, :no_definitions}
    else
      result =
        Metagame.replace_definitions!(@format, Map.take(parsed, [:definitions, :overrides]))

      Log.info(
        :importer,
        "metagame: #{@format} definitions #{result} (#{length(parsed.definitions)} rules)"
      )

      if result == :updated do
        # New vocabulary → every stored classification may be stale.
        Oban.insert(Scry2.Workers.ReclassifyArchetypes.new(%{}))
      end

      {:ok, result}
    end
  end
end
