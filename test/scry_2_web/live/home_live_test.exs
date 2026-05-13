defmodule Scry2Web.HomeLiveTest do
  use Scry2Web.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Scry2.Insights
  alias Scry2.TestFactory

  describe "mount" do
    test "renders the homepage with no tiles when nothing exists", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "h1", "Home")
    end

    test "assigns activity-mode tiles when matches exist but no insights", %{conn: conn} do
      _match = TestFactory.create_match(%{won: true, on_play: true})

      {:ok, view, _html} = live(conn, ~p"/")

      _ = render_async(view)
      tiles = :sys.get_state(view.pid).socket.assigns.tiles
      assert Enum.any?(tiles, &(&1.kind == :latest_match))
    end

    test "assigns coach insight tiles in pattern mode", %{conn: conn} do
      for _ <- 1..30, do: TestFactory.create_match(%{on_play: true, won: true})
      {:ok, _} = Insights.compute_all()

      {:ok, view, _html} = live(conn, ~p"/")

      _ = render_async(view)
      tiles = :sys.get_state(view.pid).socket.assigns.tiles
      kinds = Enum.map(tiles, & &1.kind)
      assert :coach_insight in kinds
      assert :latest_match in kinds
    end
  end

  describe "live update on insights:updates" do
    test "refreshes tiles when :insights_recomputed is broadcast", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      # Initially empty (no data) — drain the initial async load first so
      # the assertion is deterministic regardless of task scheduling.
      _ = render_async(view)
      assert :sys.get_state(view.pid).socket.assigns.tiles == []

      # Seed and recompute
      for _ <- 1..30, do: TestFactory.create_match(%{on_play: true, won: true})
      {:ok, _} = Insights.compute_all()

      # Drain the async load triggered by the :insights_recomputed broadcast
      _ = render_async(view)
      tiles = :sys.get_state(view.pid).socket.assigns.tiles
      assert tiles != []
    end
  end
end
