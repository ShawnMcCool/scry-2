defmodule Scry2.NetDecking.OwnedIdentityTest do
  use ExUnit.Case, async: true

  alias Scry2.NetDecking.OwnedIdentity

  test "owned count for a deck card sums every printing the player owns" do
    # Deck references Roaring Furnace as arena_id 92326 (one printing).
    cards_by_arena_id = %{
      92_326 => %{name: "Roaring Furnace"},
      55 => %{name: "Lightning Bolt"}
    }

    # Player owns Roaring Furnace under two other printings, none == 92326.
    owned_by_arena_id = %{94_747 => 2, 94_748 => 1, 55 => 4}

    printings = %{
      "roaring furnace" => [92_326, 94_747, 94_748],
      "lightning bolt" => [55]
    }

    owned =
      OwnedIdentity.owned_by_representative(cards_by_arena_id, owned_by_arena_id, printings)

    assert owned[92_326] == 3
    assert owned[55] == 4
  end

  test "missing names default to zero owned" do
    cards_by_arena_id = %{1 => %{name: "Absent"}}
    owned = OwnedIdentity.owned_by_representative(cards_by_arena_id, %{}, %{})
    assert owned[1] == 0
  end
end
