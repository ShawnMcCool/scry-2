defmodule Scry2.LiveState.RevealedCardTest do
  use Scry2.DataCase, async: true

  alias Scry2.LiveState
  alias Scry2.LiveState.{BoardSnapshot, RevealedCard}

  describe "changeset/2" do
    test "requires every field" do
      changeset = RevealedCard.changeset(%RevealedCard{}, %{})

      refute changeset.valid?

      errors = errors_on(changeset)

      for key <- [:board_snapshot_id, :seat_id, :zone_id, :arena_id] do
        assert errors[key] == ["can't be blank"], "missing required: #{key}"
      end
    end

    test "valid with the required fields against an existing board snapshot" do
      {:ok, _parent} = LiveState.record_final("rc-test", %{reader_version: "0.0.1"})

      {:ok, %BoardSnapshot{id: board_id}} =
        LiveState.record_final_board("rc-test", %{
          reader_version: "0.0.1",
          zones: []
        })

      attrs = %{
        board_snapshot_id: board_id,
        seat_id: 2,
        zone_id: 4,
        arena_id: 12_345,
        position: 0
      }

      assert {:ok, _row} =
               %RevealedCard{} |> RevealedCard.changeset(attrs) |> Repo.insert()
    end

    test "defaults position to 0 when omitted" do
      {:ok, _parent} = LiveState.record_final("rc-default", %{reader_version: "0.0.1"})

      {:ok, %BoardSnapshot{id: board_id}} =
        LiveState.record_final_board("rc-default", %{
          reader_version: "0.0.1",
          zones: []
        })

      attrs = %{
        board_snapshot_id: board_id,
        seat_id: 1,
        zone_id: 4,
        arena_id: 99
      }

      {:ok, row} = %RevealedCard{} |> RevealedCard.changeset(attrs) |> Repo.insert()
      assert row.position == 0
    end
  end
end
