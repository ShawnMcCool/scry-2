defmodule Scry2Web.MatchesLiveTest do
  use Scry2Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Scry2.Settings
  alias Scry2.TestFactory, as: Factory

  setup do
    player = Factory.create_player()
    Settings.put!("active_player_id", player.id)
    %{player: player}
  end

  describe "matches dashboard — economy ticker" do
    test "shows match economy ticker on the dashboard when summaries exist", %{conn: conn} do
      Factory.create_match_economy_summary(
        mtga_match_id: "ticker-1",
        ended_at: DateTime.utc_now(),
        memory_gold_delta: 100
      )

      Factory.create_match_economy_summary(
        mtga_match_id: "ticker-2",
        ended_at: DateTime.utc_now() |> DateTime.add(-3600),
        memory_gold_delta: 250
      )

      {:ok, _view, html} = live(conn, "/matches")
      assert html =~ "Last "
      assert html =~ "matches"
    end
  end

  describe "match detail — economy card" do
    test "shows match economy card when summary exists for the match", %{conn: conn} do
      match = Factory.create_match(mtga_match_id: "econ-card-smoke-1")

      Factory.create_match_economy_summary(
        mtga_match_id: "econ-card-smoke-1",
        reconciliation_state: "complete",
        memory_gold_delta: 250,
        log_gold_delta: 250,
        diff_gold: 0
      )

      {:ok, _view, html} = live(conn, ~p"/matches/#{match.id}")
      assert html =~ "Match economy"
    end

    test "does not render economy card when no summary exists", %{conn: conn} do
      match = Factory.create_match(mtga_match_id: "econ-card-smoke-2")

      {:ok, _view, html} = live(conn, ~p"/matches/#{match.id}")
      refute html =~ "data-test=\"match-economy-card\""
    end
  end
end
