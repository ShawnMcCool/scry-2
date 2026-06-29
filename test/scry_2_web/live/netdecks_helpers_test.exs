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

  test "status_order leads with buildable, then craftable, then short" do
    assert NetdecksHelpers.status_order() == [:buildable, :craftable, :short]
  end

  test "status_meta returns presentation metadata per status" do
    for status <- [:buildable, :craftable, :short] do
      meta = NetdecksHelpers.status_meta(status)
      assert is_binary(meta.label)
      assert is_binary(meta.section)
      assert is_binary(meta.badge)
      assert is_binary(meta.icon)
    end

    assert NetdecksHelpers.status_meta(:buildable).section == "Buildable now"
    assert NetdecksHelpers.status_meta(:short).section == "Within reach"
  end

  test "cost_pips returns non-zero rarities as {rarity, count} in common→mythic order" do
    assert NetdecksHelpers.cost_pips(%{common: 0, uncommon: 2, rare: 1, mythic: 0}) ==
             [{:uncommon, 2}, {:rare, 1}]

    assert NetdecksHelpers.cost_pips(%{common: 0, uncommon: 0, rare: 0, mythic: 0}) == []
  end

  test "any_cost? reflects whether a cost map has non-zero rarities" do
    assert NetdecksHelpers.any_cost?(%{common: 0, uncommon: 0, rare: 1, mythic: 0})
    refute NetdecksHelpers.any_cost?(%{common: 0, uncommon: 0, rare: 0, mythic: 0})
  end

  test "card_row_state classifies a decklist row" do
    assert NetdecksHelpers.card_row_state(%{free?: true, owned: 0, missing: 0}) == :free
    assert NetdecksHelpers.card_row_state(%{free?: false, owned: 4, missing: 0}) == :owned
    assert NetdecksHelpers.card_row_state(%{free?: false, owned: 0, missing: 4}) == :missing
    assert NetdecksHelpers.card_row_state(%{free?: false, owned: 2, missing: 2}) == :partial
  end

  test "card_row_tone maps each state to a colour class" do
    for state <- [:free, :owned, :missing, :partial] do
      assert is_binary(NetdecksHelpers.card_row_tone(state))
    end

    assert NetdecksHelpers.card_row_tone(:owned) == "text-success"
    assert NetdecksHelpers.card_row_tone(:missing) == "text-warning"
  end

  test "unresolved_count counts unresolved references on a deck" do
    assert NetdecksHelpers.unresolved_count(%{unresolved_cards: %{"cards" => [%{}, %{}]}}) == 2
    assert NetdecksHelpers.unresolved_count(%{unresolved_cards: %{"cards" => []}}) == 0
    assert NetdecksHelpers.unresolved_count(%{unresolved_cards: nil}) == 0
  end
end
