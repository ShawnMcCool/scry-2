defmodule Scry2.Metagame.ColorName do
  @moduledoc """
  WUBRG color-identity string → the name players use: guilds, shards,
  and wedges ("Izzet", "Jeskai"), `Mono-X` for single colors, `5-Color`
  for all five. Four-color combinations have no established names and
  stay as their letters. Colorless is `""` so callers can compose names
  without a dangling prefix.
  """

  @names %{
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
    "BRG" => "Jund",
    "WUBRG" => "5-Color"
  }

  @spec name(String.t()) :: String.t()
  def name(colors) when is_binary(colors), do: Map.get(@names, colors, colors)
end
