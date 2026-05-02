defmodule Scry2.Crafts.CraftTest do
  use Scry2.DataCase, async: true

  alias Scry2.Crafts.Craft

  import Scry2.TestFactory

  describe "changeset" do
    test "accepts a complete row" do
      to_snap = create_collection_snapshot()
      from_snap = create_collection_snapshot()

      attrs = %{
        occurred_at_lower: DateTime.add(DateTime.utc_now(), -60, :second),
        occurred_at_upper: DateTime.utc_now(),
        arena_id: 91_234,
        rarity: "rare",
        quantity: 1,
        from_snapshot_id: from_snap.id,
        to_snapshot_id: to_snap.id
      }

      cs = Craft.changeset(%Craft{}, attrs)
      assert cs.valid?
    end

    test "requires occurred_at, arena_id, rarity, quantity, to_snapshot_id" do
      cs = Craft.changeset(%Craft{}, %{})
      refute cs.valid?

      for field <- [
            :occurred_at_lower,
            :occurred_at_upper,
            :arena_id,
            :rarity,
            :quantity,
            :to_snapshot_id
          ] do
        assert List.keyfind(cs.errors, field, 0), "expected #{field} to be required"
      end
    end

    test "rejects unknown rarity" do
      to_snap = create_collection_snapshot()

      attrs = %{
        occurred_at_lower: DateTime.utc_now(),
        occurred_at_upper: DateTime.utc_now(),
        arena_id: 1,
        rarity: "bogus",
        quantity: 1,
        to_snapshot_id: to_snap.id
      }

      cs = Craft.changeset(%Craft{}, attrs)
      refute cs.valid?
      assert {:rarity, _} = List.keyfind(cs.errors, :rarity, 0)
    end

    test "rejects non-positive quantity" do
      to_snap = create_collection_snapshot()

      attrs = %{
        occurred_at_lower: DateTime.utc_now(),
        occurred_at_upper: DateTime.utc_now(),
        arena_id: 1,
        rarity: "rare",
        quantity: 0,
        to_snapshot_id: to_snap.id
      }

      cs = Craft.changeset(%Craft{}, attrs)
      refute cs.valid?
      assert {:quantity, _} = List.keyfind(cs.errors, :quantity, 0)
    end

    test "accepts all four rarities" do
      to_snap = create_collection_snapshot()

      for rarity <- ~w(common uncommon rare mythic) do
        attrs = %{
          occurred_at_lower: DateTime.utc_now(),
          occurred_at_upper: DateTime.utc_now(),
          arena_id: 1,
          rarity: rarity,
          quantity: 1,
          to_snapshot_id: to_snap.id
        }

        cs = Craft.changeset(%Craft{}, attrs)
        assert cs.valid?, "rarity #{rarity} should be valid"
      end
    end
  end

  describe "unique constraint on (to_snapshot_id, arena_id)" do
    test "second insert with same pair fails" do
      to_snap = create_collection_snapshot()

      attrs = %{
        occurred_at_lower: DateTime.utc_now(),
        occurred_at_upper: DateTime.utc_now(),
        arena_id: 12_345,
        rarity: "rare",
        quantity: 1,
        to_snapshot_id: to_snap.id
      }

      assert {:ok, _} = %Craft{} |> Craft.changeset(attrs) |> Scry2.Repo.insert()
      assert {:error, cs} = %Craft{} |> Craft.changeset(attrs) |> Scry2.Repo.insert()
      assert cs.errors != []
    end

    test "different arena_id under same to_snapshot is allowed" do
      to_snap = create_collection_snapshot()

      a = %{
        occurred_at_lower: DateTime.utc_now(),
        occurred_at_upper: DateTime.utc_now(),
        arena_id: 1,
        rarity: "rare",
        quantity: 1,
        to_snapshot_id: to_snap.id
      }

      b = %{a | arena_id: 2}

      assert {:ok, _} = %Craft{} |> Craft.changeset(a) |> Scry2.Repo.insert()
      assert {:ok, _} = %Craft{} |> Craft.changeset(b) |> Scry2.Repo.insert()
    end
  end
end
