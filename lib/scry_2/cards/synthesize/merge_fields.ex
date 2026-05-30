defmodule Scry2.Cards.Synthesize.MergeFields do
  @moduledoc """
  Merges per-card fields from MTGA + Scryfall source rows into the attrs
  map persisted to `cards_cards`. Pure: no DB, no side effects.

  ## Field precedence

  | Field             | Source                                                  |
  |-------------------|---------------------------------------------------------|
  | `arena_id`        | MTGA → Scryfall                                         |
  | `name`            | Scryfall front-name → MTGA name (UI markup stripped)    |
  | `collector_number`| MTGA → Scryfall                                         |
  | `rarity`          | Scryfall string → MTGA enum decoded (token/basic/...)   |
  | `color_identity`  | Scryfall (computed) → "" (empty) when MTGA-only         |
  | `mana_value`      | Scryfall cmc rounded → MTGA mana_value                  |
  | `types`           | Scryfall type_line → MTGA enum decoded                  |
  | type booleans     | derived from final `types` string                       |
  | `is_booster`      | Scryfall booster → true (default)                       |

  Scryfall is preferred for enrichable fields because it's the de facto
  MTG metadata standard — names are exact, type lines are oracle-correct,
  and color identity is computed from rules text.
  """

  alias Scry2.Cards.{MtgaCard, ScryfallCard}

  @doc """
  Builds the attrs map for one synthesised `cards_cards` row from optional
  MTGA + Scryfall source rows. Returns `nil` when both inputs are nil.
  """
  @spec build(struct() | nil, struct() | nil) :: map() | nil
  def build(nil, nil), do: nil

  def build(mtga, scryfall) do
    arena_id = pick(mtga, scryfall, & &1.arena_id)

    types = resolve_types(mtga, scryfall)
    type_flags = derive_type_booleans(types)

    %{
      arena_id: arena_id,
      name: resolve_name(mtga, scryfall),
      collector_number: resolve_collector_number(mtga, scryfall),
      rarity: resolve_rarity(mtga, scryfall),
      color_identity: resolve_color_identity(scryfall),
      mana_value: resolve_mana_value(mtga, scryfall),
      types: types,
      is_booster: resolve_booster(mtga, scryfall),
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
  Strips MTGA's rich-text UI markup from a card name and normalises
  whitespace.

  The MTGA client's localisation strings embed presentation markup that
  is meaningless outside the game client:

    * `<nobr>…</nobr>` — non-breaking wrappers around hyphenated words
      (e.g. `<nobr>Cold-Water</nobr> Snapper`).
    * `<sprite="…" name="arena_a">` — the leading Alchemy-rebalance "A"
      icon (e.g. `<sprite=…>Baba Lysaga, Night Witch`).

  Scryfall-paired cards never reach this path (their clean name wins in
  `resolve_name/2`); only MTGA-only cards carry the markup. Removing every
  `<…>` tag and collapsing the resulting whitespace yields the plain card
  name. `nil` passes through.
  """
  @spec strip_mtga_markup(String.t() | nil) :: String.t() | nil
  def strip_mtga_markup(nil), do: nil

  def strip_mtga_markup(name) when is_binary(name) do
    name
    |> String.replace(~r/<[^>]*>/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @doc """
  Derives the eight Card type booleans from a type string.

  Works for both Scryfall `type_line` ("Legendary Creature — Goblin") and
  MTGA's decoded enum form ("Creature Land"). Substring match on each
  capitalised type word.
  """
  @spec derive_type_booleans(String.t() | nil) :: %{
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

  @doc """
  Tiebreaker between two Scryfall printings that collide on the same
  `(set, number)` join key. Picks the row most likely to be the canonical
  Oracle printing for synthesis into `cards_cards`.

  Precedence:

  1. **Drop flavor-name treatments.** Scryfall's bulk data publishes
     parody / Universes-Beyond / "anime art" overlays as separate rows at
     the same `(set, number)` with the flavor name in `name` wrapped in
     literal double-quotes (e.g. `~s("The Very Hungry Archaic")` for the
     Wildgrowth Archaic SOS overlay). These rows aren't separate printings
     — they're cosmetic variants of the canonical row — and their `name`
     field is unsuitable for `cards_cards.name`. The canonical row always
     wins against a quoted-name row.
  2. **Prefer the booster (standard pack-art) printing** over showcase /
     promo treatments when both rows pass the flavor-name check.
  3. **First wins** when nothing distinguishes them.
  """
  @spec prefer_canonical_printing(ScryfallCard.t(), ScryfallCard.t()) :: ScryfallCard.t()
  def prefer_canonical_printing(a, b) do
    cond do
      flavor_named?(a) and not flavor_named?(b) -> b
      flavor_named?(b) and not flavor_named?(a) -> a
      a.booster == true -> a
      b.booster == true -> b
      true -> a
    end
  end

  defp flavor_named?(%ScryfallCard{name: name}) when is_binary(name),
    do: String.starts_with?(name, "\"")

  defp flavor_named?(_), do: false

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

  # MTGA loc strings carry UI markup (<nobr>, <sprite>) — strip it so the
  # stored name is the plain card name.
  defp resolve_name(%MtgaCard{name: name}, _), do: strip_mtga_markup(name)
  defp resolve_name(_, _), do: nil

  defp resolve_collector_number(%MtgaCard{collector_number: num}, _)
       when is_binary(num) and num != "",
       do: num

  defp resolve_collector_number(_, %ScryfallCard{collector_number: num})
       when is_binary(num) and num != "",
       do: num

  defp resolve_collector_number(_, _), do: nil

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

  # Tokens are never in booster packs — the default-true fallback for
  # missing Scryfall data must not flip them on. Pairing.for_mtga/2
  # skips tokens, so the synthesis path always reaches this clause for
  # token rows with `scryfall = nil`.
  defp resolve_booster(%MtgaCard{is_token: true}, _), do: false
  defp resolve_booster(_mtga, %ScryfallCard{booster: b}) when is_boolean(b), do: b
  # Default true matches existing schema default — most cards are boosterable.
  defp resolve_booster(_, _), do: true
end
