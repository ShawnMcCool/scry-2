defmodule Scry2.Cards.Synthesize do
  @moduledoc """
  Synthesises the canonical `cards_cards` read model from two upstream
  sources:

  - `cards_mtga_cards` — populated from the MTGA client's
    `Raw_CardDatabase_*.mtga` SQLite (via `Scry2.Cards.MtgaClientData`).
    Canonical Arena card list — every `arena_id` MTGA assigns has an
    entry here. Zero third-party dependency.
  - `cards_scryfall_cards` — populated from Scryfall bulk data (via
    `Scry2.Cards.Scryfall`). Provides oracle metadata (oracle_text,
    type_line, image_uris) and covers rotated cards no longer in the
    local MTGA DB.

  ## Pipeline

  1. Load all MTGA + all Scryfall rows (no `arena_id` filter on Scryfall —
     ADR-038).
  2. Build three in-memory indexes: MTGA-by-arena_id, Scryfall-by-arena_id,
     Scryfall-by-`(upcase(set_code), collector_number)`. The third is the
     primary join key; `arena_id` keys are used only for the rotated-card
     pass.
  3. Extract per-set metadata via `Synthesize.SetMetadata` and upsert
     `cards_sets` from the union of MTGA + Scryfall set codes.
  4. **Primary pass:** for every MTGA card, find the matching Scryfall
     row via `Synthesize.Pairing.for_mtga/2` (joins by `(set, number)`,
     skips tokens), merge fields via `Synthesize.MergeFields.build/2`,
     and persist via `Cards.synthesize_card!/1`.
  5. **Rotated pass:** for every Scryfall card with `arena_id != nil`
     that MTGA's local DB doesn't have, persist via the Scryfall-only
     path. Filters Scryfall token rows so they don't enter `cards_cards`
     through this path.
  6. Broadcast `cards_updates` so consumers (notably `SetRosterRefresher`)
     refresh.

  ## Why `(set, number)` and not `arena_id`

  ADR-038 establishes that `(set_code, collector_number)` is the
  universal MTG printing identifier present authoritatively in both
  sources. `arena_id` is MTGA's internal row identity — Scryfall populates
  it for most Arena cards but lags weeks/months for new sets, so it's
  unreliable as a synthesis-time join key. ADR-014 still applies on the
  event side: events join `cards_cards` by `arena_id`.
  """

  alias Scry2.Cards
  alias Scry2.Cards.{Card, MtgaCard, ScryfallCard}
  alias Scry2.Cards.Synthesize.{MergeFields, Pairing, SetMetadata}
  alias Scry2.Repo
  alias Scry2.Topics

  require Scry2.Log, as: Log

  @type run_result ::
          {:ok,
           %{
             synthesized: non_neg_integer(),
             mtga: non_neg_integer(),
             rotated: non_neg_integer()
           }}

  @doc """
  Runs the full synthesis pipeline. Returns counts: `synthesized` (total
  rows written), `mtga` (rows produced by the MTGA-primary pass), and
  `rotated` (rows produced by the Scryfall-only pass for cards the user's
  local MTGA DB doesn't have).
  """
  @spec run(keyword()) :: run_result()
  def run(_opts \\ []) do
    mtga_rows = Repo.all(MtgaCard)
    scryfall_rows = Repo.all(ScryfallCard)

    mtga_by_arena_id = Map.new(mtga_rows, &{&1.arena_id, &1})
    scryfall_by_set_number = build_scryfall_by_set_number(scryfall_rows)

    set_meta_by_code = SetMetadata.extract(scryfall_rows)
    set_ids_by_code = upsert_sets(mtga_rows, scryfall_rows, set_meta_by_code)

    mtga_count = synthesise_mtga(mtga_rows, scryfall_by_set_number, set_ids_by_code)

    rotated_count =
      synthesise_rotated(scryfall_rows, mtga_by_arena_id, set_ids_by_code)

    total = mtga_count + rotated_count
    Topics.broadcast(Topics.cards_updates(), {:cards_refreshed, total})

    Log.info(
      :importer,
      "synthesised #{total} cards (mtga=#{mtga_count}, rotated=#{rotated_count})"
    )

    {:ok, %{synthesized: total, mtga: mtga_count, rotated: rotated_count}}
  end

  # ── Indexing ──────────────────────────────────────────────────────────────

  defp build_scryfall_by_set_number(scryfall_rows) do
    Enum.reduce(scryfall_rows, %{}, fn
      %ScryfallCard{set_code: code, collector_number: num} = card, acc
      when is_binary(code) and code != "" and is_binary(num) and num != "" ->
        key = {String.upcase(code), num}
        Map.update(acc, key, card, &MergeFields.prefer_canonical_printing(&1, card))

      _, acc ->
        acc
    end)
  end

  # ── Primary pass: every MTGA card synthesises with (set, number)-paired
  # Scryfall enrichment ───────────────────────────────────────────────────

  defp synthesise_mtga(mtga_rows, scryfall_by_set_number, set_ids_by_code) do
    Enum.reduce(mtga_rows, 0, fn mtga, acc ->
      scryfall = Pairing.for_mtga(mtga, scryfall_by_set_number)

      attrs =
        mtga
        |> MergeFields.build(scryfall)
        |> Map.put(:set_id, resolve_set_id(set_ids_by_code, mtga, scryfall))

      Cards.synthesize_card!(attrs)
      acc + 1
    end)
  end

  # ── Rotated pass: Scryfall cards with arena_id that aren't in MTGA's
  # local DB. Filters Scryfall tokens (`layout == "token"`) so the
  # rotated path doesn't bypass the token-skip rule that the primary
  # pass enforces via `Pairing` ──────────────────────────────────────────

  defp synthesise_rotated(scryfall_rows, mtga_by_arena_id, set_ids_by_code) do
    scryfall_rows
    |> Enum.filter(fn s ->
      not is_nil(s.arena_id) and
        not Map.has_key?(mtga_by_arena_id, s.arena_id) and
        s.layout != "token"
    end)
    |> Enum.reduce(0, fn scryfall, acc ->
      attrs =
        nil
        |> MergeFields.build(scryfall)
        |> Map.put(:set_id, resolve_set_id(set_ids_by_code, nil, scryfall))

      Cards.synthesize_card!(attrs)
      acc + 1
    end)
  end

  # ── Set upsert ────────────────────────────────────────────────────────────

  defp upsert_sets(mtga_rows, scryfall_rows, set_meta_by_code) do
    mtga_codes =
      mtga_rows
      |> Enum.map(& &1.expansion_code)
      |> Enum.reject(&blank?/1)
      |> Enum.map(&String.upcase/1)
      |> MapSet.new()

    scryfall_codes =
      scryfall_rows
      |> Enum.map(& &1.set_code)
      |> Enum.reject(&blank?/1)
      |> Enum.map(&String.upcase/1)
      |> MapSet.new()

    all_codes = MapSet.union(mtga_codes, scryfall_codes)

    Map.new(all_codes, fn code ->
      meta = Map.get(set_meta_by_code, code, %{name: nil, released_at: nil})

      set =
        Cards.upsert_set!(%{
          code: code,
          name: meta.name || code,
          released_at: meta.released_at
        })

      {code, set.id}
    end)
  end

  defp resolve_set_id(set_ids_by_code, _mtga, %ScryfallCard{set_code: code})
       when is_binary(code) and code != "" do
    Map.get(set_ids_by_code, String.upcase(code))
  end

  defp resolve_set_id(set_ids_by_code, %MtgaCard{expansion_code: code}, _)
       when is_binary(code) and code != "" do
    Map.get(set_ids_by_code, String.upcase(code))
  end

  defp resolve_set_id(_, _, _), do: nil

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  # `Card.t()` reference exists to silence the unused-alias warning on
  # platforms that don't otherwise pull it in via dialyzer.
  @compile {:no_warn_unused, [Card]}
end
