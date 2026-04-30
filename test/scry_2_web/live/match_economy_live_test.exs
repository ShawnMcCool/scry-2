defmodule Scry2Web.MatchEconomyLiveTest do
  use Scry2Web.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Scry2.TestFactory

  test "renders the page with summaries", %{conn: conn} do
    create_match_economy_summary(
      mtga_match_id: "live-1",
      ended_at: DateTime.utc_now(),
      memory_gold_delta: 100
    )

    {:ok, _view, html} = live(conn, "/match-economy")
    assert html =~ "Match economy"
    assert html =~ "live-1"
  end

  test "shows empty state when no data", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/match-economy")
    assert html =~ "No match-economy data"
  end

  test "filter event updates the listed matches", %{conn: conn} do
    create_match_economy_summary(
      mtga_match_id: "out-of-range",
      ended_at: ~U[2026-04-29 10:00:00Z]
    )

    create_match_economy_summary(
      mtga_match_id: "in-range",
      ended_at: ~U[2026-04-30 10:00:00Z]
    )

    {:ok, view, _html} = live(conn, "/match-economy")
    html = render_change(view, "filter", %{"since" => "2026-04-30", "until" => "2026-04-30"})
    assert html =~ "in-range"
    refute html =~ "out-of-range"
  end
end
