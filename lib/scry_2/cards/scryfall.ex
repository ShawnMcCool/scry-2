defmodule Scry2.Cards.Scryfall do
  @moduledoc """
  Downloads Scryfall "Default Cards" bulk data and persists every card
  into `cards_scryfall_cards`.

  ## Source

  <https://scryfall.com/docs/api/bulk-data>

  Scryfall data is used under their published API terms.

  ## Pipeline

  1. GET the bulk-data catalog to obtain the rotating `download_uri`.
  2. Stream-download the ~80 MB JSON file to a temp path.
  3. Decode the JSON file with Jason, calling `parse_card/1` on every object.
  4. For each parsed card, upsert into `cards_scryfall_cards` via
     `Cards.upsert_scryfall_card!/1`.

  Synthesis into `cards_cards` lives in `Scry2.Cards.Synthesize` — this
  module just keeps the Scryfall mirror table fresh.
  """

  alias Scry2.Cards
  alias Scry2.Config
  alias Scry2.Topics

  require Scry2.Log, as: Log

  @type run_result :: {:ok, %{persisted: non_neg_integer()}} | {:error, term()}

  @doc """
  Fetches Scryfall bulk data and persists all cards into `cards_scryfall_cards`.

  Options:
    * `:url` — overrides the configured catalog URL (useful for tests)
    * `:req_options` — extra options merged into Req requests, e.g.
      `[plug: {Req.Test, __MODULE__}]` for stubbed HTTP in tests
  """
  @spec run(keyword()) :: run_result()
  def run(opts \\ []) do
    url = Keyword.get(opts, :url, Config.get(:cards_scryfall_bulk_url))
    req_options = Keyword.get(opts, :req_options, [])

    tmp_path = tmp_path()

    result =
      with {:ok, download_uri} <- fetch_download_uri(url, req_options),
           {:ok, ^tmp_path} <- download_to_temp(download_uri, req_options, tmp_path) do
        stats = process_stream(tmp_path)

        # cards_scryfall_cards was just rewritten, so its cached on-disk size
        # is stale.
        Cards.invalidate_storage_stats()
        Topics.broadcast(Topics.cards_updates(), {:scryfall_imported, stats.persisted})

        Log.info(:importer, "scryfall: persisted #{stats.persisted}")

        {:ok, stats}
      end

    cleanup_temp(tmp_path)
    result
  end

  @doc """
  Extracts all typed columns from a raw Scryfall card map.

  Pure function — no HTTP, no DB. Exposed for unit testing.

  Returns `nil` only if required fields (`id`, `name`, `set`) are absent or
  non-binary. Every card — including those without an `arena_id` — is parsed
  for persistence.
  """
  @spec parse_card(map()) :: map() | nil
  def parse_card(%{"id" => scryfall_id, "name" => name, "set" => set} = card)
      when is_binary(scryfall_id) and is_binary(name) and is_binary(set) do
    %{
      scryfall_id: scryfall_id,
      oracle_id: card["oracle_id"],
      arena_id: card["arena_id"],
      name: name,
      set_code: set,
      set_name: card["set_name"],
      released_at: parse_date(card["released_at"]),
      collector_number: card["collector_number"],
      type_line: card["type_line"],
      oracle_text: card["oracle_text"],
      mana_cost: card["mana_cost"],
      cmc: parse_cmc(card["cmc"]),
      colors: join_list(card["colors"]),
      color_identity: join_list(card["color_identity"]),
      rarity: card["rarity"],
      layout: card["layout"],
      booster: card["booster"],
      image_uris: resolve_image_uris(card),
      promo: card["promo"] == true,
      full_art: card["full_art"] == true,
      variation: card["variation"] == true,
      frame_effects: join_words(card["frame_effects"]),
      border_color: card["border_color"]
    }
  end

  def parse_card(_), do: nil

  # ── Internals ───────────────────────────────────────────────────────────

  defp parse_cmc(nil), do: nil
  defp parse_cmc(value) when is_number(value), do: value / 1
  defp parse_cmc(_), do: nil

  defp parse_date(nil), do: nil

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_), do: nil

  defp join_list(nil), do: ""
  defp join_list(list) when is_list(list), do: Enum.join(list)
  defp join_list(value) when is_binary(value), do: value

  defp join_words(nil), do: ""
  defp join_words(list) when is_list(list), do: Enum.join(list, " ")
  defp join_words(value) when is_binary(value), do: value

  # Double-faced layouts publish images per face, not at the top level —
  # the front face's art stands in for the card.
  defp resolve_image_uris(%{"image_uris" => uris}) when is_map(uris), do: uris

  defp resolve_image_uris(%{"card_faces" => [%{"image_uris" => uris} | _]}) when is_map(uris),
    do: uris

  defp resolve_image_uris(_), do: nil

  @scryfall_headers [
    {"user-agent", "Scry2/0.1.0 (personal project; no bulk scraping)"},
    {"accept", "application/json"}
  ]

  defp fetch_download_uri(nil, _req_options), do: {:error, :no_url_configured}

  defp fetch_download_uri(url, req_options) do
    options =
      Keyword.merge([url: url, receive_timeout: 30_000, headers: @scryfall_headers], req_options)

    case Req.get(options) do
      {:ok, %Req.Response{status: 200, body: %{"jsonl_download_uri" => uri}}}
      when is_binary(uri) ->
        {:ok, uri}

      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:error, {:missing_download_uri, body}}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, {:http, reason}}
    end
  end

  defp download_to_temp(url, req_options, tmp_path) do
    file_stream = File.stream!(tmp_path, 65_536)

    options =
      Keyword.merge(
        [url: url, receive_timeout: 120_000, into: file_stream, headers: @scryfall_headers],
        req_options
      )

    case Req.get(options) do
      {:ok, %Req.Response{status: 200}} ->
        {:ok, tmp_path}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, {:http, reason}}
    end
  end

  defp process_stream(tmp_path) do
    # Wrap in a transaction so SQLite doesn't fsync after every INSERT.
    # Without this, 113k individual inserts take 10+ minutes on SQLite.
    Scry2.Repo.transaction(
      fn ->
        tmp_path
        |> jsonl_lines()
        |> Enum.reduce(%{persisted: 0}, fn line, stats ->
          case line |> Jason.decode!() |> parse_card() do
            nil ->
              stats

            parsed ->
              Cards.upsert_scryfall_card!(parsed)
              %{stats | persisted: stats.persisted + 1}
          end
        end)
      end,
      timeout: :infinity
    )
    |> case do
      {:ok, stats} -> stats
      {:error, reason} -> raise "Scryfall import transaction failed: #{inspect(reason)}"
    end
  end

  # Scryfall serves bulk data as a gzip *file* — `content-type: application/gzip`
  # with no `content-encoding` — so Req hands us the compressed bytes and we
  # inflate them here. Streamed rather than `File.read!/1 |> :zlib.gunzip/1`
  # because the file is ~77 MB compressed and expands to several hundred MB.
  defp jsonl_lines(path) do
    path
    |> File.stream!(262_144)
    |> Stream.transform(&open_gzip/0, &inflate_chunk/2, &close_gzip/1)
    # A JSONL file need not end with a newline, and the splitter below only
    # emits on one — without this sentinel the last card would be dropped.
    |> Stream.concat([<<?\n>>])
    |> Stream.transform("", &split_lines/2)
    |> Stream.reject(&(&1 == ""))
  end

  defp open_gzip do
    stream = :zlib.open()
    # 15 window bits + 16 to expect a gzip (rather than zlib) wrapper.
    :ok = :zlib.inflateInit(stream, 31)
    stream
  end

  # `inflate/2` returns nested iodata, not a binary — flatten it here so the
  # line splitter can concatenate. (A small input happens to come back as a
  # single flat binary, so this only shows up on realistically-sized files.)
  defp inflate_chunk(chunk, stream) do
    {[IO.iodata_to_binary(:zlib.inflate(stream, chunk))], stream}
  end

  # `close/1` rather than `inflateEnd/1` + `close/1`: `inflateEnd/1` raises on a
  # truncated stream, which would mask the real download error.
  defp close_gzip(stream), do: :zlib.close(stream)

  # Inflated chunks do not align to line boundaries, so carry the trailing
  # partial line forward as the accumulator.
  defp split_lines(chunk, buffer) do
    [partial | complete] = (buffer <> chunk) |> String.split("\n") |> Enum.reverse()
    {Enum.reverse(complete), partial}
  end

  defp tmp_path do
    Path.join(
      System.tmp_dir!(),
      "scry2_scryfall_bulk_#{System.unique_integer([:positive])}.jsonl.gz"
    )
  end

  defp cleanup_temp(path) do
    File.rm(path)
    :ok
  end
end
