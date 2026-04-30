defmodule Scry2.LiveState.SnapshotTest do
  use Scry2.DataCase, async: true

  alias Scry2.LiveState.Snapshot

  describe "changeset/2" do
    test "valid with required fields" do
      changeset =
        Snapshot.changeset(%Snapshot{}, %{
          mtga_match_id: "abc-123",
          reader_version: "0.0.1",
          captured_at: DateTime.utc_now()
        })

      assert changeset.valid?
    end

    test "invalid without mtga_match_id" do
      changeset =
        Snapshot.changeset(%Snapshot{}, %{
          reader_version: "0.0.1",
          captured_at: DateTime.utc_now()
        })

      refute changeset.valid?
      assert {"can't be blank", _} = changeset.errors[:mtga_match_id]
    end

    test "casts integer-list commander ids via IntList type" do
      changeset =
        Snapshot.changeset(%Snapshot{}, %{
          mtga_match_id: "abc-456",
          reader_version: "0.0.1",
          captured_at: DateTime.utc_now(),
          local_commander_grp_ids: [74_116],
          opponent_commander_grp_ids: [74_117, 74_118]
        })

      assert changeset.valid?

      {:ok, snapshot} = Repo.insert(changeset)
      reloaded = Repo.get!(Snapshot, snapshot.id)

      assert reloaded.local_commander_grp_ids == [74_116]
      assert reloaded.opponent_commander_grp_ids == [74_117, 74_118]
    end

    test "rejects non-integer commander id list" do
      changeset =
        Snapshot.changeset(%Snapshot{}, %{
          mtga_match_id: "abc-789",
          reader_version: "0.0.1",
          captured_at: DateTime.utc_now(),
          local_commander_grp_ids: ["not", "ints"]
        })

      refute changeset.valid?
      assert {"is invalid", _} = changeset.errors[:local_commander_grp_ids]
    end
  end
end
