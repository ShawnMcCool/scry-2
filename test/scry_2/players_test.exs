defmodule Scry2.PlayersTest do
  use Scry2.DataCase

  alias Scry2.Players
  alias Scry2.TestFactory
  alias Scry2.Topics

  describe "get_or_create!/2" do
    test "creates a new player on first encounter" do
      player = Players.get_or_create!("ABC123", "Alice")

      assert player.mtga_user_id == "ABC123"
      assert player.screen_name == "Alice"
      assert player.first_seen_at
      assert player.id
    end

    test "returns existing player when mtga_user_id matches" do
      first = Players.get_or_create!("ABC123", "Alice")
      second = Players.get_or_create!("ABC123", "Alice")

      assert first.id == second.id
    end

    test "updates screen_name when it changes" do
      Players.get_or_create!("ABC123", "Alice")
      updated = Players.get_or_create!("ABC123", "Alice Renamed")

      assert updated.screen_name == "Alice Renamed"
    end

    test "broadcasts :player_discovered on first encounter" do
      Topics.subscribe(Topics.players_updates())

      Players.get_or_create!("NEW123", "NewPlayer")

      assert_received {:player_discovered, player}
      assert player.mtga_user_id == "NEW123"
    end

    test "broadcasts :player_updated when screen_name changes" do
      Players.get_or_create!("ABC123", "Alice")
      Topics.subscribe(Topics.players_updates())

      Players.get_or_create!("ABC123", "Alice Renamed")

      assert_received {:player_updated, player}
      assert player.screen_name == "Alice Renamed"
    end

    test "does not broadcast when nothing changed" do
      Players.get_or_create!("ABC123", "Alice")
      Topics.subscribe(Topics.players_updates())

      Players.get_or_create!("ABC123", "Alice")

      refute_received {:player_discovered, _}
      refute_received {:player_updated, _}
    end
  end

  describe "list_players/0" do
    test "returns players ordered by first_seen_at" do
      TestFactory.create_player(mtga_user_id: "P1", screen_name: "First")
      TestFactory.create_player(mtga_user_id: "P2", screen_name: "Second")

      players = Players.list_players()

      assert length(players) == 2
      assert hd(players).screen_name == "First"
    end
  end

  describe "get_player/1" do
    test "returns the player by id" do
      created = TestFactory.create_player(mtga_user_id: "P1")

      assert Players.get_player(created.id).mtga_user_id == "P1"
    end

    test "returns nil for unknown id" do
      assert Players.get_player(999_999) == nil
    end
  end

  describe "count/0" do
    test "returns the number of players" do
      assert Players.count() == 0

      TestFactory.create_player(mtga_user_id: "P1")
      TestFactory.create_player(mtga_user_id: "P2")

      assert Players.count() == 2
    end
  end
end
