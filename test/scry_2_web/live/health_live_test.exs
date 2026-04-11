defmodule Scry2Web.HealthLiveTest do
  use Scry2Web.ConnCase
  import Phoenix.LiveViewTest

  describe "mount" do
    test "renders the Health title and at least one category section", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "h1", "Health")
      # Every report has at least one ingestion check; category label
      # should render.
      assert has_element?(view, "h2", "Ingestion")
    end

    test "renders the reset setup tour button", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "button", "Run setup tour again")
    end
  end

  describe "reset_setup event" do
    test "clears the setup flag and navigates to /setup", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert {:error, {:live_redirect, %{to: "/setup"}}} =
               view |> element("button", "Run setup tour again") |> render_click()

      refute Scry2.SetupFlow.completed_persisted?()
    end
  end

  describe "health report rendering" do
    test "renders every category header", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "h2", "Ingestion")
      assert has_element?(view, "h2", "Card Data")
      assert has_element?(view, "h2", "Processing")
      assert has_element?(view, "h2", "Configuration")
    end
  end
end
