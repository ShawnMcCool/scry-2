defmodule Scry2Web.SetupLiveTest do
  use Scry2Web.ConnCase
  import Phoenix.LiveViewTest

  alias Scry2.Settings

  describe "mount and step rendering" do
    test "renders the welcome step on initial mount", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      # Welcome-step signal: the "I've enabled Detailed Logs" button label
      # is only rendered for the welcome step, so this one assertion
      # proves the correct step is mounted.
      assert has_element?(view, "button", "I've enabled Detailed Logs")
    end
  end

  describe "navigation" do
    test "clicking through the Next button walks all six steps", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      # Welcome → Locate Log
      view |> element("button", "I've enabled Detailed Logs") |> render_click()
      refute has_element?(view, "button", "I've enabled Detailed Logs")

      # Locate Log → Card Status → Verify Events → Memory Reading → Done
      view |> element("button[phx-click='next']") |> render_click()
      view |> element("button[phx-click='next']") |> render_click()
      view |> element("button[phx-click='next']") |> render_click()
      view |> element("button[phx-click='next']") |> render_click()

      # At the final step the Next button is replaced by "Go to dashboard"
      assert has_element?(view, "button", "Go to dashboard")
      refute has_element?(view, "button[phx-click='next']")
    end

    test "clicking Back moves to the previous step", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      # Advance twice to get to step 3, then back once to step 2.
      view |> element("button[phx-click='next']") |> render_click()
      view |> element("button[phx-click='next']") |> render_click()
      view |> element("button[phx-click='previous']") |> render_click()

      # Back to step 2 should restore the "next" button (which doesn't
      # exist on welcome) and the Back button should still be present.
      assert has_element?(view, "button[phx-click='next']")
      assert has_element?(view, "button[phx-click='previous']")
    end
  end

  describe "finish" do
    test "marks setup completed and navigates to /", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      # Click Next 5 times to reach Done.
      for _ <- 1..5 do
        view |> element("button[phx-click='next']") |> render_click()
      end

      assert {:error, {:live_redirect, %{to: "/"}}} =
               view |> element("button", "Go to dashboard") |> render_click()

      assert is_binary(Settings.get("setup_completed_at"))
    end
  end

  describe "memory reading toggle on the tour" do
    test "is on by default and persists off when clicked", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      # Advance to the memory_reading step (4 clicks from welcome).
      view |> element("button", "I've enabled Detailed Logs") |> render_click()
      view |> element("button[phx-click='next']") |> render_click()
      view |> element("button[phx-click='next']") |> render_click()
      view |> element("button[phx-click='next']") |> render_click()

      assert has_element?(view, "input[phx-click='toggle_live_polling']")
      assert Scry2.LiveState.enabled?()

      view
      |> element("input[phx-click='toggle_live_polling']")
      |> render_click()

      assert Settings.get("live_match_polling_enabled") == false
      refute Scry2.LiveState.enabled?()
    end
  end

  describe "manual path entry" do
    @tag :tmp_dir
    test "persists a valid manual path", %{conn: conn, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "Player.log")
      File.write!(path, "")

      {:ok, view, _html} = live(conn, ~p"/setup")
      view |> element("button[phx-click='next']") |> render_click()

      # Auto-detection may succeed on a developer machine where MTGA is
      # installed — in that case the manual form isn't rendered and we
      # have nothing to test. Skip gracefully.
      if has_element?(view, "form[phx-submit='save_manual_path']") do
        view
        |> form("form[phx-submit='save_manual_path']", path: path)
        |> render_submit()

        assert Settings.get("mtga_logs_player_log_path") == path
      end
    end

    @tag :tmp_dir
    test "shows an error row for a nonexistent path", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/setup")
      view |> element("button[phx-click='next']") |> render_click()

      if has_element?(view, "form[phx-submit='save_manual_path']") do
        missing = Path.join(tmp_dir, "does-not-exist.log")

        view
        |> form("form[phx-submit='save_manual_path']", path: missing)
        |> render_submit()

        assert has_element?(view, ".text-error")
      end
    end
  end
end
