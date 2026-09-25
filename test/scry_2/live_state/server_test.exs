defmodule Scry2.LiveState.ServerTest do
  use Scry2.DataCase, async: false

  alias Phoenix.PubSub
  alias Scry2.Events.Match.{MatchCompleted, MatchCreated}
  alias Scry2.LiveState
  alias Scry2.LiveState.Server
  alias Scry2.LiveState.Snapshot
  alias Scry2.MtgaMemory.TestBackend
  alias Scry2.Topics

  @match_id "test-match-1"
  @mtga_pid 12_345

  defp build_match_info(%{
         opponent_screen_name: opp_name,
         opponent_ranking_class: opp_class,
         opponent_ranking_tier: opp_tier
       }) do
    %{
      local: %{
        screen_name: "Me",
        seat_id: 1,
        team_id: 1,
        ranking_class: 5,
        ranking_tier: 4,
        mythic_percentile: 0,
        mythic_placement: 0,
        commander_grp_ids: []
      },
      opponent: %{
        screen_name: opp_name,
        seat_id: 2,
        team_id: 2,
        ranking_class: opp_class,
        ranking_tier: opp_tier,
        mythic_percentile: 0,
        mythic_placement: 0,
        commander_grp_ids: [74_116]
      },
      match_id: @match_id,
      format: 1,
      variant: 0,
      session_type: 0,
      current_game_number: 1,
      match_state: 1,
      local_player_seat_id: 1,
      is_practice_game: false,
      is_private_game: false,
      reader_version: "test-0.0.1"
    }
  end

  defp start_server_with_fixture(fixture, opts \\ []) do
    # `:on_init` runs inside the GenServer's own process during init/1
    # so the TestBackend fixture lands in the right process dictionary.
    full_opts =
      Keyword.merge(
        [
          name: nil,
          memory: TestBackend,
          poll_interval_ms: 20,
          match_timeout_ms: 60_000,
          on_init: fn -> TestBackend.set_fixture(fixture) end
        ],
        opts
      )

    {:ok, pid} = Server.start_link(full_opts)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp send_match_created(match_id, opponent_screen_name \\ "Lagun4") do
    event = %MatchCreated{
      player_id: 1,
      mtga_match_id: match_id,
      event_name: "Play_Ranked",
      opponent_screen_name: opponent_screen_name,
      opponent_user_id: nil,
      platform: "PC",
      opponent_platform: "PC",
      opponent_rank_class: "Diamond",
      opponent_rank_tier: 4,
      opponent_leaderboard_percentile: nil,
      opponent_leaderboard_placement: nil,
      player_rank: nil,
      format: "BO1",
      format_type: "Standard",
      deck_name: nil,
      occurred_at: DateTime.utc_now()
    }

    PubSub.broadcast(
      Scry2.PubSub,
      Topics.domain_events(),
      {:domain_event, 1, "match_created", event}
    )
  end

  defp send_match_completed(match_id) do
    event = %MatchCompleted{
      mtga_match_id: match_id,
      occurred_at: DateTime.utc_now(),
      won: true,
      num_games: 2
    }

    PubSub.broadcast(
      Scry2.PubSub,
      Topics.domain_events(),
      {:domain_event, 2, "match_completed", event}
    )
  end

  describe "polling lifecycle" do
    setup do
      :ok = PubSub.subscribe(Scry2.PubSub, LiveState.updates_topic())
      :ok = PubSub.subscribe(Scry2.PubSub, LiveState.final_topic())
      :ok
    end

    test "MatchCreated → POLLING → tick broadcast → MatchCompleted → final snapshot persisted" do
      _server =
        start_server_with_fixture(%{
          processes: [%{pid: @mtga_pid, name: "MTGA.exe", cmdline: "MTGA.exe"}],
          match_info:
            build_match_info(%{
              opponent_screen_name: "Lagun4",
              opponent_ranking_class: 5,
              opponent_ranking_tier: 4
            })
        })

      send_match_created(@match_id, "Lagun4")

      assert_receive {:tick, %{opponent: %{screen_name: "Lagun4"}}}, 500

      send_match_completed(@match_id)

      assert_receive {:final, %Snapshot{} = snapshot}, 500
      assert snapshot.mtga_match_id == @match_id
      assert snapshot.opponent_screen_name == "Lagun4"
      assert snapshot.opponent_ranking_class == 5
      assert snapshot.opponent_ranking_tier == 4
      assert snapshot.opponent_commander_grp_ids == [74_116]
    end

    test "scene torn down (walk returns nil) winds down even without MatchCompleted" do
      # match_info: nil simulates MatchSceneManager.Instance going null.
      _server =
        start_server_with_fixture(%{
          processes: [%{pid: @mtga_pid, name: "MTGA.exe", cmdline: "MTGA.exe"}],
          match_info: nil
        })

      send_match_created(@match_id)

      assert_receive {:final, %Snapshot{mtga_match_id: @match_id}}, 500
    end

    test "ignores MatchCreated when feature flag is disabled" do
      Scry2.Settings.put!("live_match_polling_enabled", false)
      on_exit(fn -> Scry2.Settings.delete("live_match_polling_enabled") end)

      _server =
        start_server_with_fixture(%{
          processes: [%{pid: @mtga_pid, name: "MTGA.exe", cmdline: "MTGA.exe"}],
          match_info:
            build_match_info(%{
              opponent_screen_name: "ShouldNotPoll",
              opponent_ranking_class: 1,
              opponent_ranking_tier: 1
            })
        })

      send_match_created("disabled-match")

      refute_receive {:tick, _}, 100
      refute_receive {:final, _}, 100
    end

    test "ignores MatchCompleted for an unrelated match while polling" do
      _server =
        start_server_with_fixture(%{
          processes: [%{pid: @mtga_pid, name: "MTGA.exe", cmdline: "MTGA.exe"}],
          match_info:
            build_match_info(%{
              opponent_screen_name: "Player",
              opponent_ranking_class: 5,
              opponent_ranking_tier: 4
            })
        })

      send_match_created(@match_id)
      assert_receive {:tick, _}, 500

      # Different match id — must NOT trigger wind-down.
      send_match_completed("unrelated-match")
      refute_receive {:final, _}, 100

      # Real completion still works.
      send_match_completed(@match_id)
      assert_receive {:final, %Snapshot{mtga_match_id: @match_id}}, 500
    end

    test "stays IDLE when MTGA process is not found" do
      _server =
        start_server_with_fixture(%{
          processes: [],
          match_info:
            build_match_info(%{
              opponent_screen_name: "Player",
              opponent_ranking_class: 5,
              opponent_ranking_tier: 4
            })
        })

      send_match_created(@match_id)

      refute_receive {:tick, _}, 100
      refute_receive {:final, _}, 100
    end

    test "winds down when walk_match_info returns an error (MTGA gone mid-match)" do
      # Simulates MTGA quitting mid-match: the cached mtga_pid is still
      # in our state, but reads against it now fail. Without this gate
      # the GenServer keeps re-polling indefinitely; if the walker hits
      # a non-terminating pointer chase on garbage memory it pegs a
      # dirty-IO scheduler at 100% CPU and the GenServer can never
      # process its own match_timeout.
      _server =
        start_server_with_fixture(%{
          processes: [%{pid: @mtga_pid, name: "MTGA.exe", cmdline: "MTGA.exe"}],
          match_info: {:error, :mono_dll_read_failed}
        })

      send_match_created(@match_id)

      assert_receive {:final, %Snapshot{mtga_match_id: @match_id}}, 500
      refute_receive {:tick, _}, 100
    end
  end
end
