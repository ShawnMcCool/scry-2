defmodule Scry2.NetDecking.CompositionKeyTest do
  use ExUnit.Case, async: true

  alias Scry2.NetDecking.CompositionKey

  @resolved [
    %{"arena_id" => 13_491, "count" => 4},
    %{"arena_id" => 66_537, "count" => 12}
  ]

  @unresolved [
    %{"name" => "Armadillo Cloak", "set_code" => nil, "collector_number" => nil, "count" => 4},
    %{"name" => "Spirit Link", "set_code" => "ULG", "collector_number" => "17", "count" => 2}
  ]

  test "identical inputs produce the same key" do
    assert CompositionKey.compute(@resolved, @unresolved) ==
             CompositionKey.compute(@resolved, @unresolved)
  end

  test "the key is a lowercase hex digest" do
    key = CompositionKey.compute(@resolved, @unresolved)

    assert is_binary(key)
    assert String.length(key) == 64
    assert key == String.downcase(key)
    assert Regex.match?(~r/^[0-9a-f]+$/, key)
  end

  test "entry order never changes the key" do
    assert CompositionKey.compute(@resolved, @unresolved) ==
             CompositionKey.compute(Enum.reverse(@resolved), Enum.reverse(@unresolved))
  end

  test "unresolved entries split across printings collapse into one summed count" do
    split = [
      %{"name" => "Gruul Turf", "set_code" => "RAV", "collector_number" => "298", "count" => 1},
      %{"name" => "Gruul Turf", "set_code" => "MMA", "collector_number" => "231", "count" => 1}
    ]

    merged = [
      %{"name" => "Gruul Turf", "set_code" => nil, "collector_number" => nil, "count" => 2}
    ]

    assert CompositionKey.compute(@resolved, split) == CompositionKey.compute(@resolved, merged)
  end

  test "unresolved names match case- and whitespace-insensitively" do
    assert CompositionKey.compute([], [%{"name" => "Gruul Turf", "count" => 2}]) ==
             CompositionKey.compute([], [%{"name" => "  gruul turf ", "count" => 2}])
  end

  test "a different resolved count is a different composition" do
    changed = [
      %{"arena_id" => 13_491, "count" => 3},
      %{"arena_id" => 66_537, "count" => 12}
    ]

    refute CompositionKey.compute(@resolved, @unresolved) ==
             CompositionKey.compute(changed, @unresolved)
  end

  test "a different unresolved card list is a different composition" do
    refute CompositionKey.compute(@resolved, @unresolved) ==
             CompositionKey.compute(@resolved, [%{"name" => "Lifelink", "count" => 1}])
  end

  test "an all-unresolved list still gets a key" do
    assert is_binary(CompositionKey.compute([], @unresolved))
  end

  test "an empty composition has no key" do
    assert CompositionKey.compute([], []) == nil
  end
end
