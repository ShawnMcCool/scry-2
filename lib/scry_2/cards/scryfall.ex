defmodule Scry2.Cards.Scryfall do
  @moduledoc """
  Downloads Scryfall "Default Cards" bulk data, persists every card into
  `cards_scryfall_cards`, and backfills `arena_id` on `cards_cards` rows
  that were imported from 17lands but lack an MTGA identifier.

  ## Source

  <https://scryfall.com/docs/api/bulk-data>

  Scryfall data is used under their published API terms.

  ## Pipeline

  1. GET the bulk-data catalog to obtain the rotating `download_uri`.
  2. Stream-download the ~80 MB JSON file to a temp path.
  3. Decode the JSON file with Jason, calling `parse_card/1` on every object.
  4. For each parsed card, upsert into `cards_scryfall_cards` via
     `Cards.upsert_scryfall_card!/1`.
  5. For cards with a non-nil `arena_id`, look up the 17lands card by
     `(name, set_code)` and call `Cards.backfill_arena_id!/2`.
  6. ADR-014: 17lands cards with an existing `arena_id` are skipped (no-op).
  """

  alias Scry2.Cards
  alias Scry2.Config
  alias Scry2.Topics

  require Scry2.Log, as: Log

  @type run_result ::
          {:ok,
           %{matched: non_neg_integer(), skipped: non_neg_integer(), persisted: non_neg_integer()}}
          | {:error, term()}

  @doc """
  Fetches Scryfall bulk data, persists all cards, and backfills `arena_id` on
  matching 17lands cards.

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
        Topics.broadcast(Topics.cards_updates(), {:arena_ids_backfilled, stats.matched})

        Log.info(
          :importer,
          "scryfall: persisted #{stats.persisted}, matched #{stats.matched}, skipped #{stats.skipped}"
        )

        {:ok, stats}
      end

    cleanup_temp(tmp_path)
    result
  end

  @doc """
  Extracts all typed columns from a raw Scryfall card map, preserving the full
  raw JSON in `:raw`.

  Pure function — no HTTP, no DB. Exposed for unit testing.

  Returns `nil` only if required fields (`id`, `name`, `set`) are absent or
  non-binary. Every card — including those without an `arena_id` — is parsed
  for persistence. Name splitting and set code upcasing are applied only in
  the backfill path (where 17lands matching requires them), not here.
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
      image_uris: card["image_uris"]
    }
  end

  def parse_card(_), do: nil

  # ── Internals ───────────────────────────────────────────────────────────

  defp parse_cmc(nil), do: nil
  defp parse_cmc(value) when is_number(value), do: value / 1
  defp parse_cmc(_), do: nil

  defp join_list(nil), do: ""
  defp join_list(list) when is_list(list), do: Enum.join(list)
  defp join_list(value) when is_binary(value), do: value

  @scryfall_headers [
    {"user-agent", "Scry2/0.1.0 (personal project; no bulk scraping)"},
    {"accept", "application/json"}
  ]

  defp fetch_download_uri(nil, _req_options), do: {:error, :no_url_configured}

  defp fetch_download_uri(url, req_options) do
    options =
      Keyword.merge([url: url, receive_timeout: 30_000, headers: @scryfall_headers], req_options)

    case Req.get(options) do
      {:ok, %Req.Response{status: 200, body: %{"download_uri" => uri}}} when is_binary(uri) ->
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
        |> File.read!()
        |> Jason.decode!()
        |> Enum.reduce(%{matched: 0, skipped: 0, persisted: 0}, fn card_map, stats ->
          case parse_card(card_map) do
            nil ->
              stats

            parsed ->
              Cards.upsert_scryfall_card!(parsed)
              stats = %{stats | persisted: stats.persisted + 1}

              if parsed.arena_id do
                front_name = parsed.name |> String.split(" // ") |> hd()
                set_code = String.upcase(parsed.set_code)
                maybe_backfill(front_name, set_code, parsed.arena_id, stats)
              else
                %{stats | skipped: stats.skipped + 1}
              end
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

  defp maybe_backfill(name, set_code, arena_id, stats) do
    case Cards.get_by_name_and_set(name, set_code) do
      [] ->
        %{stats | skipped: stats.skipped + 1}

      cards ->
        # Find the first card without an arena_id. If all already have one,
        # this is a no-op (idempotent).
        card = Enum.find(cards, &is_nil(&1.arena_id))

        if card do
          try do
            {:ok, _} = Cards.backfill_arena_id!(card, arena_id)
            %{stats | matched: stats.matched + 1}
          rescue
            _error in [Ecto.ConstraintError, Ecto.InvalidChangesetError] ->
              Log.warning(
                :importer,
                "scryfall backfill: arena_id #{arena_id} already taken, skipping #{name} (#{set_code})"
              )

              %{stats | skipped: stats.skipped + 1}
          end
        else
          %{stats | skipped: stats.skipped + 1}
        end
    end
  end

  defp tmp_path do
    Path.join(System.tmp_dir!(), "scry2_scryfall_bulk_#{System.unique_integer([:positive])}.json")
  end

  defp cleanup_temp(path) do
    File.rm(path)
    :ok
  end
end
