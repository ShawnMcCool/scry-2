defmodule Scry2.Cards.SeventeenLands do
  @moduledoc """
  Downloads the 17lands public `cards.csv` and upserts each row into the
  `cards_cards` table (and deduplicates sets into `cards_sets`).

  ## Source

  <https://17lands-public.s3.amazonaws.com/analysis_data/cards/cards.csv>

  Licensed CC BY 4.0 — see CLAUDE.md "17lands Data Provenance".

  ## Upsert strategy

  The primary unique key is `lands17_id` (17lands' internal `id`
  column). Existing rows are updated in place. Existing `arena_id`
  values are NEVER overwritten (see ADR-014) — they're backfilled from
  Scryfall in a separate path that isn't part of this first import.

  ## Column handling

  The parser is tolerant of column order and extra columns 17lands
  might add later. The known columns we actively map are:

    * `id`             → `cards_cards.lands17_id`
    * `expansion`      → `cards_sets.code` + `cards_cards.set_id`
    * `name`           → `cards_cards.name`
    * `rarity`         → `cards_cards.rarity`
    * `color_identity` → `cards_cards.color_identity`
    * `mana_value`     → `cards_cards.mana_value`
    * `types`          → `cards_cards.types`
    * `is_booster`     → `cards_cards.is_booster`

  Every row's original column map is retained verbatim as
  `cards_cards.raw`, so new columns become available without a
  migration.
  """

  alias Scry2.Cards
  alias Scry2.Config
  alias Scry2.Topics

  NimbleCSV.define(__MODULE__.Parser, separator: ",", escape: "\"")

  @type run_result :: {:ok, %{imported: non_neg_integer()}} | {:error, term()}

  @doc """
  Fetches `cards.csv` and imports every row.

  Options:
    * `:url` — overrides the configured URL (useful for tests)
    * `:req_options` — extra options merged into the Req request, e.g.
      `[plug: {Req.Test, __MODULE__}]` for stubbed HTTP in tests
  """
  @spec run(keyword()) :: run_result()
  def run(opts \\ []) do
    url = Keyword.get(opts, :url, Config.get(:cards_lands17_url))
    req_options = Keyword.get(opts, :req_options, [])

    with {:ok, csv} <- fetch(url, req_options),
         {:ok, rows} <- safe_parse(csv) do
      imported = import_rows(rows)
      Topics.broadcast(Topics.cards_updates(), {:cards_refreshed, imported})
      {:ok, %{imported: imported}}
    end
  end

  @doc """
  Parses raw CSV text into a list of row maps `%{column_name => value}`.

  Pure function — no HTTP, no DB. Exposed for unit testing.
  """
  @spec parse_csv(binary()) :: [map()]
  def parse_csv(csv) when is_binary(csv) do
    case __MODULE__.Parser.parse_string(csv, skip_headers: false) do
      [headers | rows] ->
        Enum.map(rows, fn values ->
          headers
          |> Enum.zip(values)
          |> Map.new()
        end)

      [] ->
        []
    end
  end

  # ── Internals ───────────────────────────────────────────────────────────

  defp fetch(nil, _opts), do: {:error, :no_url_configured}

  defp fetch(url, req_options) do
    options = Keyword.merge([url: url, receive_timeout: 30_000, decode_body: false], req_options)

    case Req.get(options) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, {:http, reason}}
    end
  end

  defp safe_parse(csv) do
    {:ok, parse_csv(csv)}
  rescue
    error -> {:error, {:csv_parse, error}}
  end

  defp import_rows(rows) do
    # Dedupe sets by expansion code first to avoid N upserts per set.
    set_ids_by_code = upsert_sets(rows)

    Enum.reduce(rows, 0, fn row, count ->
      case row_to_card_attrs(row, set_ids_by_code) do
        nil ->
          count

        attrs ->
          Cards.upsert_card!(attrs)
          count + 1
      end
    end)
  end

  defp upsert_sets(rows) do
    rows
    |> Enum.map(&Map.get(&1, "expansion"))
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
    |> Map.new(fn code ->
      set = Cards.upsert_set!(%{code: code, name: code})
      {code, set.id}
    end)
  end

  defp row_to_card_attrs(row, set_ids_by_code) do
    with lands17_id when is_integer(lands17_id) <- parse_int(row["id"]),
         name when is_binary(name) and name != "" <- row["name"] do
      types = row["types"] || ""

      %{
        lands17_id: lands17_id,
        name: name,
        rarity: row["rarity"],
        color_identity: row["color_identity"] || "",
        mana_value: parse_int(row["mana_value"]),
        types: types,
        is_booster: parse_bool(row["is_booster"]),
        is_creature: String.contains?(types, "Creature"),
        is_instant: String.contains?(types, "Instant"),
        is_sorcery: String.contains?(types, "Sorcery"),
        is_enchantment: String.contains?(types, "Enchantment"),
        is_artifact: String.contains?(types, "Artifact"),
        is_planeswalker: String.contains?(types, "Planeswalker"),
        is_land: String.contains?(types, "Land"),
        is_battle: String.contains?(types, "Battle"),
        set_id: Map.get(set_ids_by_code, row["expansion"]),
        raw: row
      }
    else
      _ -> nil
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil
  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_bool("true"), do: true
  defp parse_bool("True"), do: true
  defp parse_bool("TRUE"), do: true
  defp parse_bool(true), do: true
  defp parse_bool("false"), do: false
  defp parse_bool("False"), do: false
  defp parse_bool("FALSE"), do: false
  defp parse_bool(false), do: false
  defp parse_bool(_), do: true
end
