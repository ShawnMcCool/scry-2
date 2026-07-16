defmodule Scry2.Metagame.ColorNameTest do
  use ExUnit.Case, async: true

  alias Scry2.Metagame.ColorName

  test "colorless is empty" do
    assert ColorName.name("") == ""
  end

  test "single colors are Mono-X" do
    assert ColorName.name("W") == "Mono-White"
    assert ColorName.name("U") == "Mono-Blue"
    assert ColorName.name("B") == "Mono-Black"
    assert ColorName.name("R") == "Mono-Red"
    assert ColorName.name("G") == "Mono-Green"
  end

  test "guild pairs" do
    assert ColorName.name("WU") == "Azorius"
    assert ColorName.name("WB") == "Orzhov"
    assert ColorName.name("WR") == "Boros"
    assert ColorName.name("WG") == "Selesnya"
    assert ColorName.name("UB") == "Dimir"
    assert ColorName.name("UR") == "Izzet"
    assert ColorName.name("UG") == "Simic"
    assert ColorName.name("BR") == "Rakdos"
    assert ColorName.name("BG") == "Golgari"
    assert ColorName.name("RG") == "Gruul"
  end

  test "shards and wedges" do
    assert ColorName.name("WUB") == "Esper"
    assert ColorName.name("WUR") == "Jeskai"
    assert ColorName.name("WUG") == "Bant"
    assert ColorName.name("WBR") == "Mardu"
    assert ColorName.name("WBG") == "Abzan"
    assert ColorName.name("WRG") == "Naya"
    assert ColorName.name("UBR") == "Grixis"
    assert ColorName.name("UBG") == "Sultai"
    assert ColorName.name("URG") == "Temur"
    assert ColorName.name("BRG") == "Jund"
  end

  test "four-color stays as letters, five-color is 5-Color" do
    assert ColorName.name("WUBR") == "WUBR"
    assert ColorName.name("WUBRG") == "5-Color"
  end
end
