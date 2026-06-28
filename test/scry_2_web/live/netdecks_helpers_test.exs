defmodule Scry2Web.NetdecksHelpersTest do
  use ExUnit.Case, async: true

  alias Scry2Web.NetdecksHelpers

  test "format_cost renders non-zero rarities compactly" do
    assert NetdecksHelpers.format_cost(%{common: 0, uncommon: 2, rare: 1, mythic: 0}) == "2u 1r"
    assert NetdecksHelpers.format_cost(%{common: 0, uncommon: 0, rare: 0, mythic: 0}) == "—"
    assert NetdecksHelpers.format_cost(%{common: 1, uncommon: 0, rare: 0, mythic: 3}) == "1c 3m"
  end

  test "format_owned_pct renders a whole-percent string" do
    assert NetdecksHelpers.format_owned_pct(1.0) == "100%"
    assert NetdecksHelpers.format_owned_pct(0.82) == "82%"
  end

  test "match_search? matches name and archetype case-insensitively" do
    entry = %{deck: %{name: "Mono-Red Aggro", archetype: "Aggro"}}
    assert NetdecksHelpers.match_search?(entry, "mono")
    assert NetdecksHelpers.match_search?(entry, "aggro")
    refute NetdecksHelpers.match_search?(entry, "control")
    assert NetdecksHelpers.match_search?(entry, "")
  end
end
