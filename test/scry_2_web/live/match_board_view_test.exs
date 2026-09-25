defmodule Scry2Web.Live.MatchBoardViewTest do
  @moduledoc """
  Display grouping for the revealed-cards section. Rows now come from
  the `matches_revealed_cards` projection with semantic zone slugs
  rather than MTGA `CardHolderType` integers — see ADR-047.
  """
  use ExUnit.Case, async: true

  alias Scry2.Matches.RevealedCard
  alias Scry2Web.Live.MatchBoardView

  defp card(seat_id, zone, arena_id, is_local \\ nil) do
    %RevealedCard{
      mtga_match_id: "m-1",
      seat_id: seat_id,
      is_local: is_local,
      current_zone: zone,
      arena_id: arena_id,
      copies_seen: 1
    }
  end

  describe "group_by_seat_and_zone/1" do
    test "returns [] for empty input" do
      assert MatchBoardView.group_by_seat_and_zone([]) == []
    end

    test "groups rows by seat then zone" do
      rows = [
        card(1, "battlefield", 101, true),
        card(1, "battlefield", 102, true),
        card(2, "battlefield", 201, false),
        card(2, "battlefield", 202, false),
        card(2, "battlefield", 203, false)
      ]

      assert [you, opp] = MatchBoardView.group_by_seat_and_zone(rows)

      assert you.seat_id == 1
      assert you.label == "You"
      assert [%{zone: "battlefield", label: "Battlefield", arena_ids: [101, 102]}] = you.zones

      assert opp.seat_id == 2
      assert opp.label == "Opponent"

      assert [%{zone: "battlefield", label: "Battlefield", arena_ids: [201, 202, 203]}] =
               opp.zones
    end

    test "sorts cards within a zone deterministically even if rows are shuffled" do
      rows = [
        card(2, "battlefield", 999),
        card(2, "battlefield", 111),
        card(2, "battlefield", 555)
      ]

      assert [%{zones: [%{arena_ids: [111, 555, 999]}]}] =
               MatchBoardView.group_by_seat_and_zone(rows)
    end

    test "orders by role, so the local player leads even from seat 2" do
      rows = [
        card(3, "battlefield", 301, nil),
        card(1, "battlefield", 101, false),
        card(2, "battlefield", 201, true)
      ]

      groups = MatchBoardView.group_by_seat_and_zone(rows)

      assert Enum.map(groups, & &1.seat_id) == [2, 1, 3]
      assert Enum.map(groups, & &1.label) == ["You", "Opponent", "Seat 3"]
    end

    test "an all-false seat is labelled Opponent, not left unresolved" do
      # Regression: picking the role with find_value/2 returns nil for a
      # seat whose rows are all `false`, silently demoting the opponent to
      # an unknown seat.
      rows = [card(2, "battlefield", 201, false), card(2, "hand", 202, false)]

      assert [group] = MatchBoardView.group_by_seat_and_zone(rows)
      assert group.label == "Opponent"
      assert group.is_local == false
    end

    test "orders a seat's zones by how a player reads the board" do
      rows = [
        card(2, "exile", 600),
        card(2, "battlefield", 400),
        card(2, "graveyard", 500),
        card(2, "hand", 450)
      ]

      assert [%{seat_id: 2, zones: zones}] = MatchBoardView.group_by_seat_and_zone(rows)
      assert Enum.map(zones, & &1.zone) == ["battlefield", "hand", "graveyard", "exile"]

      assert Enum.map(zones, & &1.label) == [
               "Battlefield",
               "Hand",
               "Graveyard",
               "Exile"
             ]
    end

    test "an unresolved zone sorts last rather than being dropped" do
      rows = [
        card(1, nil, 700),
        card(1, "battlefield", 100)
      ]

      assert [%{zones: zones}] = MatchBoardView.group_by_seat_and_zone(rows)
      assert Enum.map(zones, & &1.zone) == ["battlefield", nil]
      assert List.last(zones).label == "Unknown zone"
    end
  end

  describe "seat_label/2" do
    test "names a seat by its resolved role, not its number" do
      # The local player alternates seats between matches, so seat 2 is
      # "You" just as often as seat 1 is. ADR-047.
      assert MatchBoardView.seat_label(1, true) == "You"
      assert MatchBoardView.seat_label(2, true) == "You"
      assert MatchBoardView.seat_label(1, false) == "Opponent"
      assert MatchBoardView.seat_label(2, false) == "Opponent"
    end

    test "shows the seat number rather than guessing when the role is unknown" do
      assert MatchBoardView.seat_label(7, nil) == "Seat 7"
      assert MatchBoardView.seat_label(1, nil) == "Seat 1"
    end
  end

  describe "revealed_arena_ids/1" do
    test "returns [] for empty input" do
      assert MatchBoardView.revealed_arena_ids([]) == []
    end

    test "returns unique arena_ids across all seats and zones" do
      rows = [
        card(1, "battlefield", 101),
        card(1, "graveyard", 102),
        card(2, "battlefield", 201),
        # Same card revealed for both seats — one download suffices.
        card(2, "graveyard", 101)
      ]

      assert MatchBoardView.revealed_arena_ids(rows) |> Enum.sort() == [101, 102, 201]
    end
  end

  describe "zone_label/1" do
    test "names the zones a player actually sees" do
      assert MatchBoardView.zone_label("battlefield") == "Battlefield"
      assert MatchBoardView.zone_label("hand") == "Hand"
      assert MatchBoardView.zone_label("graveyard") == "Graveyard"
      assert MatchBoardView.zone_label("exile") == "Exile"
      assert MatchBoardView.zone_label("stack") == "Stack"
      assert MatchBoardView.zone_label("library") == "Library"
      assert MatchBoardView.zone_label("command") == "Command"
    end

    test "titlecases an unmapped zone rather than hiding it" do
      assert MatchBoardView.zone_label("ZoneType_Newthing") == "Zonetype newthing"
      assert MatchBoardView.zone_label("some_new_zone") == "Some new zone"
    end

    test "labels a missing zone" do
      assert MatchBoardView.zone_label(nil) == "Unknown zone"
    end
  end
end
