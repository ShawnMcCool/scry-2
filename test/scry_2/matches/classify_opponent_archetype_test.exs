defmodule Scry2.Matches.ClassifyOpponentArchetypeTest do
  use Scry2.DataCase, async: false

  import Scry2.TestFactory

  alias Scry2.LiveState
  alias Scry2.Matches
  alias Scry2.Matches.ClassifyOpponentArchetype
  alias Scry2.Topics

  setup do
    Scry2.Metagame.replace_definitions!("Standard", %{
      definitions: [
        %{
          key: "Burn",
          kind: "archetype",
          name: "Burn",
          include_color_in_name: true,
          conditions: [%{"type" => "InMainboard", "cards" => ["Lightning Bolt"]}],
          variants: [],
          common_cards: []
        }
      ],
      overrides: []
    })

    bolt = create_card(name: "Lightning Bolt", color_identity: "R")
    mountain = create_card(name: "Mountain", color_identity: "R", is_land: true)
    %{bolt: bolt, mountain: mountain}
  end

  defp record_boards(mtga_match_id, opponent_arena_ids) do
    {:ok, _snapshot} =
      LiveState.record_final(mtga_match_id, %{
        reader_version: "0.0.1",
        local_seat_id: 1,
        opponent_seat_id: 2
      })

    {:ok, board} =
      LiveState.record_final_board(mtga_match_id, %{
        reader_version: "0.0.1",
        zones: [
          %{seat_id: 1, zone_id: 4, arena_ids: [999_999]},
          %{seat_id: 2, zone_id: 4, arena_ids: opponent_arena_ids}
        ]
      })

    board
  end

  describe "classify_opponent_archetype/1" do
    test "stamps the opponent archetype from their revealed cards", context do
      Topics.subscribe(Topics.matches_updates())
      match = create_match(%{mtga_match_id: "OA-1", format_type: "Constructed"})

      record_boards("OA-1", [
        context.bolt.arena_id,
        context.bolt.arena_id,
        context.mountain.arena_id
      ])

      assert :ok = Matches.classify_opponent_archetype("OA-1")

      reloaded = Repo.reload(match)
      assert reloaded.opponent_archetype == "Mono-Red Burn"
      assert reloaded.opponent_archetype_confidence == "confirmed"
      assert_receive {:match_updated, _id}, 200
    end

    test "skips Limited matches", context do
      match = create_match(%{mtga_match_id: "OA-2", format_type: "Limited"})
      record_boards("OA-2", [context.bolt.arena_id])

      assert :ok = Matches.classify_opponent_archetype("OA-2")
      assert Repo.reload(match).opponent_archetype == nil
    end

    test "no-ops when no match row exists", context do
      record_boards("OA-3", [context.bolt.arena_id])
      assert :ok = Matches.classify_opponent_archetype("OA-3")
    end

    test "no-ops when there is no live-state snapshot" do
      create_match(%{mtga_match_id: "OA-4", format_type: "Constructed"})
      assert :ok = Matches.classify_opponent_archetype("OA-4")
    end

    test "clears a stale stamp when classification becomes unknown", context do
      match = create_match(%{mtga_match_id: "OA-5", format_type: "Constructed"})
      record_boards("OA-5", [context.bolt.arena_id])

      assert :ok = Matches.classify_opponent_archetype("OA-5")
      # No land observed, so color falls back to the nonland set (R).
      assert Repo.reload(match).opponent_archetype == "Mono-Red Burn"

      Scry2.Metagame.replace_definitions!("Standard", %{
        definitions: [
          %{
            key: "Never",
            kind: "archetype",
            name: "Never",
            include_color_in_name: false,
            conditions: [%{"type" => "InMainboard", "cards" => ["Nonexistent"]}],
            variants: [],
            common_cards: []
          }
        ],
        overrides: []
      })

      assert :ok = Matches.classify_opponent_archetype("OA-5")
      assert Repo.reload(match).opponent_archetype == nil
    end
  end

  describe "reclassify_opponent_archetypes!/0" do
    test "re-stamps every match with revealed cards", context do
      match = create_match(%{mtga_match_id: "OA-6", format_type: "Constructed"})
      record_boards("OA-6", [context.bolt.arena_id, context.mountain.arena_id])

      assert Matches.reclassify_opponent_archetypes!() == 1
      assert Repo.reload(match).opponent_archetype == "Mono-Red Burn"

      # A second pass changes nothing.
      assert Matches.reclassify_opponent_archetypes!() == 0
    end
  end

  describe "consumer" do
    test "classifies when the final board broadcast arrives", context do
      match = create_match(%{mtga_match_id: "OA-7", format_type: "Constructed"})

      name = :"classify_opponent_archetype_#{System.unique_integer([:positive])}"
      {:ok, pid} = ClassifyOpponentArchetype.start_link(name: name)

      record_boards("OA-7", [
        context.bolt.arena_id,
        context.mountain.arena_id
      ])

      :sys.get_state(pid)

      assert Repo.reload(match).opponent_archetype == "Mono-Red Burn"
      GenServer.stop(pid)
    end

    test "ignores unrelated messages" do
      name = :"classify_opponent_archetype_#{System.unique_integer([:positive])}"
      {:ok, pid} = ClassifyOpponentArchetype.start_link(name: name)

      send(pid, :unrelated)
      :sys.get_state(pid)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end
end
