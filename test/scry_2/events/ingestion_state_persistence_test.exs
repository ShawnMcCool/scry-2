defmodule Scry2.Events.IngestionStatePersistenceTest do
  use Scry2.DataCase

  alias Scry2.Events.IngestionState
  alias Scry2.Events.IngestionState.{Match, Session}

  describe "persist!/1 and load/0" do
    test "round-trips through the database" do
      state = %IngestionState{
        version: 1,
        last_raw_event_id: 99,
        session: %Session{self_user_id: "user-1", player_id: 5, constructed_rank: "Gold 2"},
        match: %Match{current_match_id: "m-xyz", current_game_number: 1}
      }

      IngestionState.persist!(state)
      loaded = IngestionState.load()

      assert loaded.last_raw_event_id == 99
      assert loaded.session.self_user_id == "user-1"
      assert loaded.session.player_id == 5
      assert loaded.session.constructed_rank == "Gold 2"
      assert loaded.match.current_match_id == "m-xyz"
    end

    test "load/0 returns fresh state when no snapshot exists" do
      assert IngestionState.load() == IngestionState.new()
    end

    test "persist!/1 overwrites existing snapshot" do
      IngestionState.persist!(%IngestionState{
        last_raw_event_id: 1,
        session: %Session{},
        match: %Match{}
      })

      IngestionState.persist!(%IngestionState{
        last_raw_event_id: 2,
        session: %Session{},
        match: %Match{}
      })

      loaded = IngestionState.load()
      assert loaded.last_raw_event_id == 2
    end
  end
end
