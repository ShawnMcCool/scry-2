defmodule Scry2.Matches.ProjectorTest do
  use Scry2.DataCase

  alias Scry2.Events
  alias Scry2.Events.{MatchCompleted, MatchCreated}
  alias Scry2.Matches
  alias Scry2.Matches.Projector

  setup do
    # Start the projector under the test supervisor. Unique name per
    # test to avoid conflicts with the application-supervised one (off
    # in test env, but keeping robust is cheap).
    name = Module.concat(__MODULE__, :"Projector#{System.unique_integer([:positive])}")
    pid = start_supervised!({Projector, name: name})
    %{projector: name, pid: pid}
  end

  defp sync(name), do: :sys.get_state(name) && :ok

  describe "projects %MatchCreated{} → matches_matches" do
    test "creates a new row with expected fields", %{projector: name} do
      event = %MatchCreated{
        mtga_match_id: "proj-1",
        event_name: "Traditional_Ladder",
        opponent_screen_name: "Opponent1",
        started_at: ~U[2026-04-05 19:18:40Z]
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
        started_at: ~U[2026-04-05 19:18:40Z]
      }

      completed = %MatchCompleted{
        mtga_match_id: "proj-2",
        ended_at: ~U[2026-04-05 19:53:36Z],
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
        started_at: ~U[2026-04-05 19:18:40Z]
      }

      Events.append!(event, nil)
      Events.append!(event, nil)
      sync(name)

      assert Matches.count() == 1
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
