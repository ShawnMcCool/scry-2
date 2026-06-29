defmodule Scry2.NetDecking.DeckQualities do
  @moduledoc """
  Pure derivation of a netdeck's display qualities from its maindeck cards:
  color identity, the signature (hero + secondary) cards, the canonical
  color-combo name, and the deck's newest set. No DB, no side effects — the
  caller supplies `card_entries` (`[%{arena_id, count}]`) and a
  `%{arena_id => %Card{}}` lookup.
  """

  @combos %{
    "" => "Colorless",
    "W" => "Mono-White",
    "U" => "Mono-Blue",
    "B" => "Mono-Black",
    "R" => "Mono-Red",
    "G" => "Mono-Green",
    "WU" => "Azorius",
    "WB" => "Orzhov",
    "WR" => "Boros",
    "WG" => "Selesnya",
    "UB" => "Dimir",
    "UR" => "Izzet",
    "UG" => "Simic",
    "BR" => "Rakdos",
    "BG" => "Golgari",
    "RG" => "Gruul",
    "WUB" => "Esper",
    "WUR" => "Jeskai",
    "WUG" => "Bant",
    "WBR" => "Mardu",
    "WBG" => "Abzan",
    "WRG" => "Naya",
    "UBR" => "Grixis",
    "UBG" => "Sultai",
    "URG" => "Temur",
    "BRG" => "Jund"
  }

  @doc "Canonical name for a WUBRG-ordered color string (e.g. \"WR\" -> \"Boros\")."
  @spec color_combo_name(String.t()) :: String.t()
  def color_combo_name(colors) when is_binary(colors) do
    case Map.get(@combos, colors) do
      nil -> "#{String.length(colors)}-color"
      name -> name
    end
  end
end
