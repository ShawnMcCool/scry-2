defmodule Scry2.Metagame.FetchDefinitions do
  @moduledoc """
  Upstream refresh: MTGOFormatData repo tarball → parsed definition rows
  → `Scry2.Metagame.replace_definitions!/2`, once per supported format.

  One HTTP request fetches the whole repo archive; each format's
  `Formats/<Format>/` entries are extracted from the same in-memory
  archive and parsed via `ParseDefinitions` independently — one
  format's malformed file, or a format missing from this particular
  snapshot entirely, never blocks another format's update. The run as
  a whole is only rejected if *every* supported format yields zero
  archetype definitions — that's the truncated-download signature the
  original single-format guard existed to catch.
  """

  alias Scry2.Metagame
  alias Scry2.Metagame.ParseDefinitions

  require Scry2.Log, as: Log

  @url "https://github.com/Badaro/MTGOFormatData/archive/refs/heads/main.tar.gz"
  @formats ["Standard", "Modern", "Pioneer", "Pauper"]

  @spec run(keyword()) :: {:ok, :updated | :unchanged} | {:error, term()}
  def run(opts \\ []) do
    req_options = Keyword.get(opts, :req_options, [])

    with {:ok, tarball} <- download(req_options),
         {:ok, entries} <- extract(tarball) do
      apply_formats(entries)
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
      {:ok, entries} -> {:ok, entries}
      {:error, reason} -> {:error, {:tar, reason}}
    end
  end

  defp apply_formats(entries) do
    parsed_by_format =
      Map.new(@formats, fn format ->
        {format, ParseDefinitions.rows_from_files(format_files(entries, format))}
      end)

    if Enum.all?(parsed_by_format, &no_archetypes?/1) do
      {:error, :no_definitions}
    else
      results =
        Enum.map(parsed_by_format, fn {format, parsed} -> apply_format(format, parsed) end)

      {:ok, if(:updated in results, do: :updated, else: :unchanged)}
    end
  end

  defp no_archetypes?({_format, parsed}),
    do: not Enum.any?(parsed.definitions, &(&1.kind == "archetype"))

  defp apply_format(format, %{errors: errors} = parsed) do
    if no_archetypes?({format, parsed}) do
      Enum.each(errors, &log_skipped_file/1)

      Log.warning(
        :importer,
        "metagame: no #{format} archetype definitions in this fetch — skipped"
      )

      :unchanged
    else
      %{definitions: definitions, overrides: overrides} = parsed
      Enum.each(errors, &log_skipped_file/1)

      result =
        Metagame.replace_definitions!(format, %{definitions: definitions, overrides: overrides})

      Log.info(
        :importer,
        "metagame: #{format} definitions #{result} (#{length(definitions)} rules)"
      )

      if result == :updated do
        Oban.insert(Scry2.Workers.ReclassifyArchetypes.new(%{}))
      end

      result
    end
  end

  defp log_skipped_file({path, reason}) do
    Log.warning(:importer, "metagame: skipped definition file #{path}: #{inspect(reason)}")
  end

  # "MTGOFormatData-main/Formats/Modern/Archetypes/X.json" → "Archetypes/X.json"
  defp format_files(entries, format) do
    for {path_charlist, content} <- entries,
        path = List.to_string(path_charlist),
        [_prefix, relative] <- [String.split(path, "/Formats/#{format}/", parts: 2)],
        into: %{} do
      {relative, content}
    end
  end
end
