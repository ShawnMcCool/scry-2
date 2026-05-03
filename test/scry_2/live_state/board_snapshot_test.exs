defmodule Scry2.LiveState.BoardSnapshotTest do
  use Scry2.DataCase, async: true

  alias Scry2.LiveState
  alias Scry2.LiveState.BoardSnapshot

  describe "changeset/2" do
    test "requires the parent snapshot id, reader_version, and captured_at" do
      changeset = BoardSnapshot.changeset(%BoardSnapshot{}, %{})

      refute changeset.valid?

      assert %{
               live_state_snapshot_id: ["can't be blank"],
               reader_version: ["can't be blank"],
               captured_at: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "valid with the required fields against an existing parent" do
      {:ok, parent} = LiveState.record_final("bs-test", %{reader_version: "0.0.1"})

      attrs = %{
        live_state_snapshot_id: parent.id,
        reader_version: "0.0.1",
        captured_at: DateTime.utc_now()
      }

      changeset = BoardSnapshot.changeset(%BoardSnapshot{}, attrs)
      assert changeset.valid?
      assert {:ok, _board} = Repo.insert(changeset)
    end

    test "rejects duplicate insert for the same parent snapshot" do
      {:ok, parent} = LiveState.record_final("bs-dup", %{reader_version: "0.0.1"})

      attrs = %{
        live_state_snapshot_id: parent.id,
        reader_version: "0.0.1",
        captured_at: DateTime.utc_now()
      }

      {:ok, _} = %BoardSnapshot{} |> BoardSnapshot.changeset(attrs) |> Repo.insert()

      {:error, changeset} = %BoardSnapshot{} |> BoardSnapshot.changeset(attrs) |> Repo.insert()
      assert %{live_state_snapshot_id: ["has already been taken"]} = errors_on(changeset)
    end
  end
end
