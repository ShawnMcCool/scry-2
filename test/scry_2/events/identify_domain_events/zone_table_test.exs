defmodule Scry2.Events.IdentifyDomainEvents.ZoneTableTest do
  @moduledoc """
  The zone table is the ACL's one representation of "which GRE zone id
  means which zone". Every field name here is taken from real
  `GameStateMessage` payloads — see ADR-047.
  """
  use ExUnit.Case, async: true

  alias Scry2.Events.IdentifyDomainEvents.ZoneTable

  # Shape verified against 537 real zone objects decompressed from
  # mtga_logs_events on 2026-09-25: every one carries `zoneId`, `type`
  # and `visibility`; only owned zones carry `ownerSeatId`.
  defp game_state do
    %{
      "zones" => [
        %{
          "zoneId" => 28,
          "type" => "ZoneType_Battlefield",
          "visibility" => "Visibility_Public",
          "objectInstanceIds" => [358, 355]
        },
        %{
          "zoneId" => 31,
          "type" => "ZoneType_Hand",
          "visibility" => "Visibility_Private",
          "ownerSeatId" => 1,
          "objectInstanceIds" => [401, 402]
        },
        %{
          "zoneId" => 35,
          "type" => "ZoneType_Graveyard",
          "visibility" => "Visibility_Public",
          "ownerSeatId" => 2
        }
      ]
    }
  end

  describe "from_game_state/1" do
    test "keys the table by zoneId, not id" do
      table = ZoneTable.from_game_state(game_state())

      assert ZoneTable.type(table, 28) == :battlefield
      assert ZoneTable.type(table, 31) == :hand
      assert ZoneTable.type(table, 35) == :graveyard
    end

    test "resolves the owning seat for owned zones" do
      table = ZoneTable.from_game_state(game_state())

      assert ZoneTable.owner_seat(table, 31) == 1
      assert ZoneTable.owner_seat(table, 35) == 2
    end

    test "returns nil owner for shared zones" do
      table = ZoneTable.from_game_state(game_state())

      assert ZoneTable.owner_seat(table, 28) == nil
    end

    test "returns nil for unknown zone ids" do
      table = ZoneTable.from_game_state(game_state())

      assert ZoneTable.type(table, 999) == nil
      assert ZoneTable.owner_seat(table, 999) == nil
    end

    test "tolerates a message with no zones" do
      assert ZoneTable.from_game_state(%{}) == ZoneTable.new()
      assert ZoneTable.from_game_state(nil) == ZoneTable.new()
    end
  end

  describe "type/2 coverage of the real ZoneType_* vocabulary" do
    # All twelve types observed across the sampled history. An unmapped
    # type must surface as its raw string rather than silently becoming
    # nil, so a new MTGA zone is visible instead of dropped.
    test "maps every observed zone type" do
      observed = [
        {"ZoneType_Battlefield", :battlefield},
        {"ZoneType_Hand", :hand},
        {"ZoneType_Graveyard", :graveyard},
        {"ZoneType_Exile", :exile},
        {"ZoneType_Library", :library},
        {"ZoneType_Stack", :stack},
        {"ZoneType_Limbo", :limbo},
        {"ZoneType_Revealed", :revealed},
        {"ZoneType_Pending", :pending},
        {"ZoneType_Command", :command},
        {"ZoneType_Sideboard", :sideboard},
        {"ZoneType_Suppressed", :suppressed}
      ]

      for {wire, expected} <- observed do
        table = ZoneTable.from_game_state(%{"zones" => [%{"zoneId" => 1, "type" => wire}]})
        assert ZoneTable.type(table, 1) == expected, "expected #{wire} -> #{expected}"
      end
    end

    test "an unrecognised zone type surfaces rather than vanishing" do
      table =
        ZoneTable.from_game_state(%{"zones" => [%{"zoneId" => 7, "type" => "ZoneType_Newthing"}]})

      assert ZoneTable.type(table, 7) == "ZoneType_Newthing"
    end
  end

  describe "merge/2" do
    # Zone tables appear in only some GameStateMessages (roughly one in
    # three raw events), so the table must accumulate across a batch
    # rather than reset to empty on messages that omit it.
    test "later zones win, earlier zones survive" do
      first = ZoneTable.from_game_state(game_state())

      second =
        ZoneTable.from_game_state(%{
          "zones" => [
            %{"zoneId" => 31, "type" => "ZoneType_Hand", "ownerSeatId" => 2},
            %{"zoneId" => 40, "type" => "ZoneType_Exile", "visibility" => "Visibility_Public"}
          ]
        })

      merged = ZoneTable.merge(first, second)

      assert ZoneTable.type(merged, 28) == :battlefield
      assert ZoneTable.type(merged, 40) == :exile
      assert ZoneTable.owner_seat(merged, 31) == 2
    end

    test "merging an empty table changes nothing" do
      table = ZoneTable.from_game_state(game_state())

      assert ZoneTable.merge(table, ZoneTable.new()) == table
    end
  end

  describe "label/2" do
    # ZoneChanged.zone_from/zone_to have always been documented as
    # "Battlefield"/"Hand" but carried "zone_28" — GREProtocol.zone_name/1
    # only prefixed the raw id. ADR-047 makes the data match the contract.
    test "labels a known zone by its semantic name" do
      table =
        ZoneTable.from_game_state(%{
          "zones" => [
            %{"zoneId" => 28, "type" => "ZoneType_Battlefield"},
            %{"zoneId" => 31, "type" => "ZoneType_Hand"}
          ]
        })

      assert ZoneTable.label(table, 28) == "battlefield"
      assert ZoneTable.label(table, 31) == "hand"
    end

    test "falls back to the raw zone id when the zone is unknown" do
      # A transition can reference a zone whose table entry has not been
      # seen yet. Losing the id entirely would discard the transition, so
      # the id survives in the old "zone_N" form.
      assert ZoneTable.label(ZoneTable.new(), 44) == "zone_44"
    end

    test "returns nil for a nil zone id" do
      assert ZoneTable.label(ZoneTable.new(), nil) == nil
    end

    test "labels an unrecognised MTGA zone type by its wire name" do
      table =
        ZoneTable.from_game_state(%{"zones" => [%{"zoneId" => 9, "type" => "ZoneType_Newthing"}]})

      assert ZoneTable.label(table, 9) == "ZoneType_Newthing"
    end
  end
end
