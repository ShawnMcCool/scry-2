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

  describe "match detail — revealed cards" do
    test "renders revealed cards and completes the image-caching async", %{conn: conn} do
      match = Factory.create_match(mtga_match_id: "revealed-images-1")

      {:ok, _snapshot} =
        Scry2.LiveState.record_final("revealed-images-1", %{reader_version: "0.0.1"})

      {:ok, _board} =
        Scry2.LiveState.record_final_board("revealed-images-1", %{
          reader_version: "0.0.1",
          zones: [%{seat_id: 2, zone_id: 4, arena_ids: [999_991, 999_992]}]
        })

      {:ok, view, html} = live(conn, ~p"/matches/#{match.id}")
      assert html =~ "Revealed cards"

      # Drains the :cache_images start_async kicked off on detail load —
      # fails if the LiveView lacks a matching handle_async clause.
      assert render_async(view) =~ "Revealed cards"
    end
  end

  describe "match detail — opponent + rank display" do
    test "renders memory-enriched opponent screen name and rank", %{conn: conn} do
      match =
        Factory.create_match(
          mtga_match_id: "rank-detail-1",
          opponent_screen_name: "RealOpponent#42",
          opponent_rank: "Diamond 2",
          player_rank: "Platinum 4"
        )

      {:ok, _view, html} = live(conn, ~p"/matches/#{match.id}")

      assert html =~ "RealOpponent#42"
      assert html =~ "Diamond 2"
      assert html =~ "Platinum 4"
    end

    test "renders Mythic placement when opponent has placement", %{conn: conn} do
      match =
        Factory.create_match(
          mtga_match_id: "rank-detail-2",
          opponent_screen_name: "TopPlayer",
          opponent_rank: "Mythic",
          opponent_rank_mythic_placement: 142
        )

      {:ok, _view, html} = live(conn, ~p"/matches/#{match.id}")

      assert html =~ "TopPlayer"
      assert html =~ "Mythic #142"
    end

    test "renders Mythic percentile when opponent has no placement", %{conn: conn} do
      match =
        Factory.create_match(
          mtga_match_id: "rank-detail-3",
          opponent_screen_name: "Climbing",
          opponent_rank: "Mythic",
          opponent_rank_mythic_percentile: 88
        )

      {:ok, _view, html} = live(conn, ~p"/matches/#{match.id}")

      assert html =~ "Climbing"
      assert html =~ "Mythic 88%"
    end
  end
end
