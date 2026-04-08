defmodule Scry2.Matches.UpdateFromEventTest do
  use Scry2.DataCase

  alias Scry2.Events
  alias Scry2.Events.Deck.DeckSubmitted
  alias Scry2.Events.Match.{GameCompleted, MatchCompleted, MatchCreated}
  alias Scry2.Matches
  alias Scry2.Matches.UpdateFromEvent

  setup do
    # Start the projector under the test supervisor. Unique name per
    # test to avoid conflicts with the application-supervised one (off
    # in test env, but keeping robust is cheap).
    name = Module.concat(__MODULE__, :"Projector#{System.unique_integer([:positive])}")
    pid = start_supervised!({UpdateFromEvent, name: name})
    %{projector: name, pid: pid}
  end

  defp sync(name), do: :sys.get_state(name) && :ok

  describe "projects %MatchCreated{} → matches_matches" do
    test "creates a new row with expected fields", %{projector: name} do
      event = %MatchCreated{
        mtga_match_id: "proj-1",
        event_name: "Traditional_Ladder",
        opponent_screen_name: "Opponent1",
        occurred_at: ~U[2026-04-05 19:18:40Z]
      }

      Events.append!(event, nil)
      sync(name)

      match = Matches.get_by_mtga_id("proj-1")
      assert match != nil
      assert match.event_name == "Traditional_Ladder"
      assert match.opponent_screen_name == "Opponent1"
      assert match.started_at == ~U[2026-04-05 19:18:40Z]
    end
  end

  describe "projects %MatchCompleted{} → enriches existing row" do
    test "populates ended_at, won, num_games on the same mtga_match_id", %{projector: name} do
      created = %MatchCreated{
        mtga_match_id: "proj-2",
        event_name: "Traditional_Ladder",
        opponent_screen_name: "Opponent1",
        occurred_at: ~U[2026-04-05 19:18:40Z]
      }

      completed = %MatchCompleted{
        mtga_match_id: "proj-2",
        occurred_at: ~U[2026-04-05 19:53:36Z],
        won: true,
        num_games: 3,
        reason: "MatchCompletedReasonType_Success"
      }

      Events.append!(created, nil)
      Events.append!(completed, nil)
      sync(name)

      assert Matches.count() == 1
      match = Matches.get_by_mtga_id("proj-2")
      assert match.started_at == ~U[2026-04-05 19:18:40Z]
      assert match.ended_at == ~U[2026-04-05 19:53:36Z]
      assert match.won == true
      assert match.num_games == 3
    end
  end

  describe "idempotency (ADR-016)" do
    test "replaying the same MatchCreated produces exactly one row", %{projector: name} do
      event = %MatchCreated{
        mtga_match_id: "proj-3",
        event_name: "A",
        opponent_screen_name: "Opponent1",
        occurred_at: ~U[2026-04-05 19:18:40Z]
      }

      Events.append!(event, nil)
      Events.append!(event, nil)
      sync(name)

      assert Matches.count() == 1
    end
  end

  describe "projects %GameCompleted{} → matches_games" do
    test "creates a game row linked to the match", %{projector: name} do
      created = %MatchCreated{
        mtga_match_id: "proj-game-1",
        event_name: "Traditional_Ladder",
        opponent_screen_name: "Opponent1",
        occurred_at: ~U[2026-04-05 19:18:40Z]
      }

      Events.append!(created, nil)
      sync(name)

      game_event = %GameCompleted{
        mtga_match_id: "proj-game-1",
        game_number: 1,
        on_play: true,
        won: true,
        num_mulligans: 1,
        num_turns: 8,
        occurred_at: ~U[2026-04-05 19:30:00Z]
      }

      Events.append!(game_event, nil)
      sync(name)

      match =
        Matches.get_match_with_associations(Matches.get_by_mtga_id("proj-game-1").id)

      assert length(match.games) == 1

      [game] = match.games
      assert game.game_number == 1
      assert game.on_play == true
      assert game.won == true
      assert game.num_mulligans == 1
      assert game.num_turns == 8
      assert game.ended_at == ~U[2026-04-05 19:30:00Z]
    end
  end

  describe "projects %DeckSubmitted{} → matches_deck_submissions" do
    test "creates a deck submission row linked to the match", %{projector: name} do
      # Create a match first so the FK resolves.
      created = %MatchCreated{
        mtga_match_id: "proj-deck-1",
        event_name: "Traditional_Ladder",
        opponent_screen_name: "Opponent1",
        occurred_at: ~U[2026-04-05 19:18:40Z]
      }

      Events.append!(created, nil)
      sync(name)

      deck = %DeckSubmitted{
        mtga_match_id: "proj-deck-1",
        mtga_deck_id: "proj-deck-1:seat1",
        main_deck: [%{arena_id: 67810, count: 4}, %{arena_id: 100_652, count: 1}],
        sideboard: [%{arena_id: 92235, count: 1}],
        occurred_at: ~U[2026-04-05 19:18:40Z]
      }

      Events.append!(deck, nil)
      sync(name)

      match = Matches.get_by_mtga_id("proj-deck-1")

      submission =
        Scry2.Repo.get_by(Matches.DeckSubmission, mtga_deck_id: "proj-deck-1:seat1")

      assert submission != nil
      assert submission.match_id == match.id
      assert submission.submitted_at == ~U[2026-04-05 19:18:40Z]
      assert is_list(submission.main_deck) or is_map(submission.main_deck)
    end
  end

  describe "resilience" do
    test "ignores domain events outside claimed_slugs", %{projector: name, pid: pid} do
      # Manually broadcast a fake message — projector should not crash.
      Phoenix.PubSub.broadcast(
        Scry2.PubSub,
        "domain:events",
        {:domain_event, 999_999, "fake_slug_nobody_handles"}
      )

      sync(name)
      assert Process.alive?(pid)
    end
  end
end
