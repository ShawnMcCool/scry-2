defmodule Scry2.Cards.Synthesize do
  @moduledoc """
  Synthesizes the canonical `cards_cards` read model from two upstream sources:

  - `cards_mtga_cards` — populated from the MTGA client's
    `Raw_CardDatabase_*.mtga` SQLite (via `Scry2.Cards.MtgaClientData`).
    Canonical Arena card list — every `arena_id` MTGA assigns has an entry
    here. Zero third-party dependency: it's the user's own game files.
  - `cards_scryfall_cards` — populated from Scryfall bulk data (via
    `Scry2.Cards.Scryfall`). Provides oracle metadata (oracle_text, type_line,
    image_uris) and covers rotated cards no longer in the local MTGA DB.

  Each `cards_cards` row is keyed on `arena_id`. The two source indexes are
  unioned by arena_id; per-field precedence resolves conflicts.

  ## Pipeline

  1. Load all MTGA cards (already populated by MtgaClientData importer).
  2. Load all Scryfall cards with `arena_id != nil`.
  3. Union the two indexes by `arena_id`.
  4. For each arena_id, build attrs by merging fields from both sources.
  5. Upsert `cards_sets` from each card's Scryfall set code (or MTGA expansion
     fallback), then upsert `cards_cards` rows.

  ## Field precedence

  | Field            | Source                                                  |
  |------------------|---------------------------------------------------------|
  | `arena_id`       | MTGA → Scryfall                                         |
  | `name`           | Scryfall front-name → MTGA name                         |
  | `rarity`         | Scryfall string → MTGA enum decoded (token/basic/...)   |
  | `color_identity` | Scryfall (computed) → "" (empty) when MTGA-only         |
  | `mana_value`     | Scryfall cmc rounded → MTGA mana_value                  |
  | `types`          | Scryfall type_line → MTGA enum decoded                  |
  | type booleans    | derived from final `types` string                       |
  | `is_booster`     | Scryfall booster → true (default)                       |
  | `set_id`         | Scryfall set_code → MTGA expansion_code                 |

  Scryfall is preferred for enrichable fields because it's the de facto MTG
  metadata standard — names are exact, type lines are oracle-correct, and
  color identity is computed from rules text.
  """

  alias Scry2.Cards
  alias Scry2.Cards.{Card, MtgaCard, ScryfallCard}
  alias Scry2.Repo
  alias Scry2.Topics

  import Ecto.Query

  require Scry2.Log, as: Log

  @type run_result ::
          {:ok,
           %{
             synthesized: non_neg_integer(),
             mtga_only: non_neg_integer(),
             scryfall_only: non_neg_integer()
           }}

  @doc """
  Runs the full synthesis pipeline. Reads `cards_mtga_cards` and
  `cards_scryfall_cards`, then upserts `cards_cards` rows keyed on
  `arena_id`.

  Returns counts: total `synthesized`, `mtga_only` (Scryfall has no row),
  `scryfall_only` (MTGA has no row).
  """
  @spec run(keyword()) :: run_result()
  def run(_opts \\ []) do
    mtga_index =
      MtgaCard
      |> Repo.all()
      |> Map.new(&{&1.arena_id, &1})

    scryfall_index =
      ScryfallCard
      |> where([s], not is_nil(s.arena_id))
      |> Repo.all()
      |> Enum.reduce(%{}, fn card, acc ->
        # When two Scryfall printings carry the same arena_id (alt-art
        # duplicates), prefer the booster entry — it's the standard art
        # treatment used in packs.
        case Map.get(acc, card.arena_id) do
          nil -> Map.put(acc, card.arena_id, card)
          existing -> Map.put(acc, card.arena_id, prefer_booster(existing, card))
        end
      end)

    arena_ids =
      mtga_index
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.union(MapSet.new(Map.keys(scryfall_index)))

    set_ids_by_code = upsert_sets_from_sources(mtga_index, scryfall_index)

    {synthesized, mtga_only, scryfall_only} =
      Enum.reduce(arena_ids, {0, 0, 0}, fn arena_id, {syn, mo, so} ->
        mtga = Map.get(mtga_index, arena_id)
        scryfall = Map.get(scryfall_index, arena_id)

        case build_card_attrs(mtga, scryfall) do
          nil ->
            {syn, mo, so}

          attrs ->
            attrs = Map.put(attrs, :set_id, resolve_set_id(set_ids_by_code, mtga, scryfall))
            Cards.synthesize_card!(attrs)

            {
              syn + 1,
              mo + if(is_nil(scryfall), do: 1, else: 0),
              so + if(is_nil(mtga), do: 1, else: 0)
            }
        end
      end)

    Topics.broadcast(Topics.cards_updates(), {:cards_refreshed, synthesized})

    Log.info(
      :importer,
      "synthesized #{synthesized} cards (mtga_only=#{mtga_only}, scryfall_only=#{scryfall_only})"
    )

    {:ok, %{synthesized: synthesized, mtga_only: mtga_only, scryfall_only: scryfall_only}}
  end

  @doc """
  Builds card attrs from optional MTGA and Scryfall source rows. At least one
  must be non-nil.

  Returns `nil` when both inputs are nil.
  """
  @spec build_card_attrs(struct() | nil, struct() | nil) :: map() | nil
  def build_card_attrs(nil, nil), do: nil

  def build_card_attrs(mtga, scryfall) do
    arena_id = pick(mtga, scryfall, & &1.arena_id)

    types = resolve_types(mtga, scryfall)
    type_flags = derive_type_booleans(types)

    %{
      arena_id: arena_id,
      name: resolve_name(mtga, scryfall),
      rarity: resolve_rarity(mtga, scryfall),
      color_identity: resolve_color_identity(scryfall),
      mana_value: resolve_mana_value(mtga, scryfall),
      types: types,
      is_booster: resolve_booster(scryfall),
      is_creature: type_flags.is_creature,
      is_instant: type_flags.is_instant,
      is_sorcery: type_flags.is_sorcery,
      is_enchantment: type_flags.is_enchantment,
      is_artifact: type_flags.is_artifact,
      is_planeswalker: type_flags.is_planeswalker,
      is_land: type_flags.is_land,
      is_battle: type_flags.is_battle
    }
  end

  @doc """
  Returns the front-face name on a double-faced card (the segment before
  ` // `). Single-face names pass through unchanged.
  """
  @spec front_name(String.t()) :: String.t()
  def front_name(name) when is_binary(name) do
    name |> String.split(" // ") |> hd()
  end

  @doc """
  Derives the eight Card type booleans from a type string.

  Works for both Scryfall `type_line` ("Legendary Creature — Goblin") and
  MTGA's decoded enum form ("Creature Land"). Substring match on each
  capitalised type word.
  """
  @spec derive_type_booleans(String.t()) :: %{
          is_creature: boolean(),
          is_instant: boolean(),
          is_sorcery: boolean(),
          is_enchantment: boolean(),
          is_artifact: boolean(),
          is_planeswalker: boolean(),
          is_land: boolean(),
          is_battle: boolean()
        }
  def derive_type_booleans(types) when is_binary(types) do
    %{
      is_creature: String.contains?(types, "Creature"),
      is_instant: String.contains?(types, "Instant"),
      is_sorcery: String.contains?(types, "Sorcery"),
      is_enchantment: String.contains?(types, "Enchantment"),
      is_artifact: String.contains?(types, "Artifact"),
      is_planeswalker: String.contains?(types, "Planeswalker"),
      is_land: String.contains?(types, "Land"),
      is_battle: String.contains?(types, "Battle")
    }
  end

  def derive_type_booleans(_),
    do: %{
      is_creature: false,
      is_instant: false,
      is_sorcery: false,
      is_enchantment: false,
      is_artifact: false,
      is_planeswalker: false,
      is_land: false,
      is_battle: false
    }

  @doc """
  Decodes MTGA's comma-separated integer type enum to a space-joined
  human-readable string (e.g. `"2,5"` → `"Creature Land"`).

  MTGA type enum (from `Raw_CardDatabase` `Cards.Types`):
  1=Artifact, 2=Creature, 3=Enchantment, 4=Instant, 5=Land, 8=Planeswalker,
  10=Sorcery.
  """
  @spec decode_mtga_types(String.t() | nil) :: String.t()
  def decode_mtga_types(nil), do: ""
  def decode_mtga_types(""), do: ""

  def decode_mtga_types(types) when is_binary(types) do
    types
    |> String.split(",", trim: true)
    |> Enum.map(&mtga_type_name/1)
    |> Enum.join(" ")
  end

  defp mtga_type_name("1"), do: "Artifact"
  defp mtga_type_name("2"), do: "Creature"
  defp mtga_type_name("3"), do: "Enchantment"
  defp mtga_type_name("4"), do: "Instant"
  defp mtga_type_name("5"), do: "Land"
  defp mtga_type_name("8"), do: "Planeswalker"
  defp mtga_type_name("10"), do: "Sorcery"
  defp mtga_type_name(other), do: other

  # ── Field resolvers ────────────────────────────────────────────────────────

  defp pick(nil, scryfall, getter), do: getter.(scryfall)
  defp pick(mtga, nil, getter), do: getter.(mtga)
  defp pick(mtga, _scryfall, getter), do: getter.(mtga)

  defp resolve_name(_mtga, %ScryfallCard{name: name}) when is_binary(name) and name != "" do
    front_name(name)
  end

  defp resolve_name(%MtgaCard{name: name}, _), do: name
  defp resolve_name(_, _), do: nil

  defp resolve_types(_mtga, %ScryfallCard{type_line: tl}) when is_binary(tl) and tl != "" do
    # Scryfall's type_line for DFCs uses " // " between front/back.
    # The flags we derive don't care which face contributed the keyword,
    # so leaving the full line is fine — but trim the back face from the
    # display string to keep the canonical form aligned with `name`.
    tl |> String.split(" // ") |> hd()
  end

  defp resolve_types(%MtgaCard{types: types}, _) when is_binary(types) and types != "" do
    decode_mtga_types(types)
  end

  defp resolve_types(_, _), do: ""

  defp resolve_rarity(_mtga, %ScryfallCard{rarity: r}) when is_binary(r) and r != "", do: r
  defp resolve_rarity(%MtgaCard{rarity: r}, _) when is_integer(r), do: mtga_rarity_name(r)
  defp resolve_rarity(_, _), do: nil

  defp mtga_rarity_name(0), do: "token"
  defp mtga_rarity_name(1), do: "basic"
  defp mtga_rarity_name(2), do: "common"
  defp mtga_rarity_name(3), do: "uncommon"
  defp mtga_rarity_name(4), do: "rare"
  defp mtga_rarity_name(5), do: "mythic"
  defp mtga_rarity_name(_), do: nil

  defp resolve_color_identity(%ScryfallCard{color_identity: ci}) when is_binary(ci), do: ci
  defp resolve_color_identity(_), do: ""

  defp resolve_mana_value(_mtga, %ScryfallCard{cmc: cmc}) when is_number(cmc), do: round(cmc)
  defp resolve_mana_value(%MtgaCard{mana_value: mv}, _) when is_integer(mv), do: mv
  defp resolve_mana_value(_, _), do: 0

  defp resolve_booster(%ScryfallCard{booster: b}) when is_boolean(b), do: b
  # Default true matches existing schema default — most cards are boosterable.
  defp resolve_booster(_), do: true

  defp prefer_booster(%ScryfallCard{booster: true} = a, _b), do: a
  defp prefer_booster(_a, %ScryfallCard{booster: true} = b), do: b
  defp prefer_booster(a, _b), do: a

  # ── Set resolution ─────────────────────────────────────────────────────────

  defp upsert_sets_from_sources(mtga_index, scryfall_index) do
    scryfall_codes =
      scryfall_index
      |> Map.values()
      |> Enum.map(& &1.set_code)
      |> Enum.reject(&blank?/1)
      |> Enum.map(&String.upcase/1)

    mtga_codes =
      mtga_index
      |> Map.values()
      |> Enum.map(& &1.expansion_code)
      |> Enum.reject(&blank?/1)
      |> Enum.map(&String.upcase/1)

    (scryfall_codes ++ mtga_codes)
    |> Enum.uniq()
    |> Map.new(fn code ->
      set = Cards.upsert_set!(%{code: code, name: code})
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
