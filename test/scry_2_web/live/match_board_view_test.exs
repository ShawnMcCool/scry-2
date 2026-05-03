defmodule Scry2Web.Live.MatchBoardViewTest do
  use ExUnit.Case, async: true

  alias Scry2.LiveState.RevealedCard
  alias Scry2Web.Live.MatchBoardView

  defp card(seat_id, zone_id, arena_id, position \\ 0) do
    %RevealedCard{
      seat_id: seat_id,
      zone_id: zone_id,
      arena_id: arena_id,
      position: position
    }
  end

  describe "group_by_seat_and_zone/1" do
    test "returns [] for empty input" do
      assert MatchBoardView.group_by_seat_and_zone([]) == []
    end

    test "groups rows by seat then zone, preserving in-zone position order" do
      rows = [
        card(1, 4, 101, 0),
        card(1, 4, 102, 1),
        card(2, 4, 201, 0),
        card(2, 4, 202, 1),
        card(2, 4, 203, 2)
      ]

      assert [you, opp] = MatchBoardView.group_by_seat_and_zone(rows)

      assert you.seat_id == 1
      assert you.label == "You"
      assert [%{zone_id: 4, label: "Battlefield", arena_ids: [101, 102]}] = you.zones

      assert opp.seat_id == 2
      assert opp.label == "Opponent"
      assert [%{zone_id: 4, label: "Battlefield", arena_ids: [201, 202, 203]}] = opp.zones
    end

    test "sorts cards within a zone by position even if rows are shuffled" do
      rows = [
        card(2, 4, 999, 2),
        card(2, 4, 111, 0),
        card(2, 4, 555, 1)
      ]

      assert [%{zones: [%{arena_ids: [111, 555, 999]}]}] =
               MatchBoardView.group_by_seat_and_zone(rows)
    end

    test "puts local seat first, opponent second, others after in seat-id order" do
      rows = [
        card(3, 4, 301),
        card(2, 4, 201),
        card(1, 4, 101),
        card(0, 4, 1)
      ]

      groups = MatchBoardView.group_by_seat_and_zone(rows)

      assert Enum.map(groups, & &1.seat_id) == [1, 2, 0, 3]
      assert Enum.map(groups, & &1.label) == ["You", "Opponent", "Unknown", "Teammate"]
    end

    test "splits multiple zones for one seat in zone-id order" do
      rows = [
        card(2, 6, 600),
        card(2, 4, 400),
        card(2, 5, 500)
      ]

      assert [%{seat_id: 2, zones: zones}] = MatchBoardView.group_by_seat_and_zone(rows)
      assert Enum.map(zones, & &1.zone_id) == [4, 5, 6]
      assert Enum.map(zones, & &1.label) == ["Battlefield", "Graveyard", "Exile"]
    end
  end

  describe "seat_label/1" do
    test "names known seat-id enum values" do
      assert MatchBoardView.seat_label(1) == "You"
      assert MatchBoardView.seat_label(2) == "Opponent"
      assert MatchBoardView.seat_label(0) == "Unknown"
      assert MatchBoardView.seat_label(3) == "Teammate"
    end

    test "falls back to a stable label for unknown ints" do
      assert MatchBoardView.seat_label(7) == "Seat 7"
    end
  end

  describe "zone_label/1" do
    test "names every documented CardHolderType value" do
      assert MatchBoardView.zone_label(1) == "Library"
      assert MatchBoardView.zone_label(2) == "Off-camera Library"
      assert MatchBoardView.zone_label(3) == "Hand"
      assert MatchBoardView.zone_label(4) == "Battlefield"
      assert MatchBoardView.zone_label(5) == "Graveyard"
      assert MatchBoardView.zone_label(6) == "Exile"
      assert MatchBoardView.zone_label(9) == "Stack"
      assert MatchBoardView.zone_label(10) == "Command"
    end

    test "falls back for unknown zone ints" do
      assert MatchBoardView.zone_label(42) == "Zone 42"
    end
  end
end
