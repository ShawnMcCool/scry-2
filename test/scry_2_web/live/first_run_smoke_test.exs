defmodule Scry2Web.FirstRunSmokeTest do
  @moduledoc """
  End-to-end smoke test for the first-run experience. Covers:

    1. A fresh install with no setup flag redirects `/` → `/setup`.
    2. The setup tour walks through all five steps and dismisses itself.
    3. After the tour, `/` renders `HealthLive` without redirecting.
    4. The health screen's "Run setup tour again" link brings the user
       back into the tour.

  This is a single top-to-bottom test so any regression in the
  setup-tour pipeline fails loudly in one place.
  """
  use Scry2Web.ConnCase
  import Phoenix.LiveViewTest

  alias Scry2.SetupFlow

  setup do
    # ConnCase marks setup completed by default so existing tests work.
    # This test specifically wants a fresh first-run state.
    :ok = SetupFlow.reset!()
    :ok
  end

  test "first-run user completes the tour and lands on the health screen", %{conn: conn} do
    # Gate redirects fresh user away from /
    assert {:error, {:redirect, %{to: "/setup"}}} = live(conn, ~p"/")

    # Walk the tour
    {:ok, view, _html} = live(conn, ~p"/setup")
    assert has_element?(view, "button", "I've enabled Detailed Logs")

    # Four Next clicks → final step
    view |> element("button[phx-click='next']") |> render_click()
    view |> element("button[phx-click='next']") |> render_click()
    view |> element("button[phx-click='next']") |> render_click()
    view |> element("button[phx-click='next']") |> render_click()

    # Finish
    assert has_element?(view, "button", "Go to dashboard")

    assert {:error, {:live_redirect, %{to: "/"}}} =
             view |> element("button", "Go to dashboard") |> render_click()

    # Tour is now dismissed — / renders the health screen
    assert SetupFlow.completed_persisted?()
    refute SetupFlow.required?()

    {:ok, health_view, _html} = live(conn, ~p"/")
    assert has_element?(health_view, "h1", "Settings")

    # "Run setup tour again" loops back to the tour
    assert {:error, {:live_redirect, %{to: "/setup"}}} =
             health_view |> element("button", "Run setup tour again") |> render_click()

    refute SetupFlow.completed_persisted?()
  end
end
