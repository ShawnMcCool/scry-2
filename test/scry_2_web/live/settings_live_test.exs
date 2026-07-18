defmodule Scry2Web.SettingsLiveTest do
  use Scry2Web.ConnCase
  import Phoenix.LiveViewTest

  alias Scry2.Settings

  @moduletag :tmp_dir

  describe "player_log_path form" do
    test "saves a valid path to Settings", %{conn: conn, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "Player.log")
      File.write!(path, "")

      {:ok, view, _html} = live(conn, ~p"/settings")

      open_edit(view, "player_log_path")

      view
      |> form("form[phx-submit='save_player_log_path']", value: path)
      |> render_submit()

      assert Settings.get("mtga_logs_player_log_path") == path
      refute render(view) =~ "form[phx-submit='save_player_log_path']"
    end

    test "shows an error for an invalid path", %{conn: conn, tmp_dir: tmp_dir} do
      missing = Path.join(tmp_dir, "nope.log")

      {:ok, view, _html} = live(conn, ~p"/settings")

      open_edit(view, "player_log_path")

      view
      |> form("form[phx-submit='save_player_log_path']", value: missing)
      |> render_submit()

      assert has_element?(view, "p.text-error", "No file exists")
      refute Settings.get("mtga_logs_player_log_path") == missing
    end

    test "cancel hides the form without saving", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      open_edit(view, "player_log_path")
      assert render(view) =~ "save_player_log_path"

      view
      |> element("button[phx-click='cancel_edit'][phx-value-field='player_log_path']")
      |> render_click()

      refute render(view) =~ "save_player_log_path"
    end
  end

  describe "data_dir form" do
    test "saves a valid directory", %{conn: conn, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      open_edit(view, "data_dir")

      view
      |> form("form[phx-submit='save_data_dir']", value: tmp_dir)
      |> render_submit()

      assert Settings.get("mtga_logs_data_dir") == tmp_dir
    end

    test "shows an error for a missing directory", %{conn: conn, tmp_dir: tmp_dir} do
      missing = Path.join(tmp_dir, "nope")

      {:ok, view, _html} = live(conn, ~p"/settings")

      open_edit(view, "data_dir")

      view
      |> form("form[phx-submit='save_data_dir']", value: missing)
      |> render_submit()

      assert has_element?(view, "p.text-error", "No directory")
    end
  end

  describe "poll_interval_ms form" do
    test "saves a valid integer", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> form("form[phx-submit='save_poll_interval_ms']", value: "750")
      |> render_submit()

      assert Settings.get("mtga_logs_poll_interval_ms") == 750
    end

    test "shows an error for out-of-range values", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> form("form[phx-submit='save_poll_interval_ms']", value: "50")
      |> render_submit()

      assert has_element?(view, "p.text-error", "at least 100")
    end

    test "shows an error for garbage input", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> form("form[phx-submit='save_poll_interval_ms']", value: "lots")
      |> render_submit()

      assert has_element?(view, "p.text-error", "whole number")
    end
  end

  describe "build-change verification banner" do
    setup do
      Scry2.Collection.enable_reader!()
      Settings.put!("collection.acknowledged_build_hint", "BUILD-OLD")

      Scry2.TestFactory.create_collection_snapshot(
        entries: [{30_001, 1}],
        reader_confidence: "fallback_scan",
        mtga_build_hint: "BUILD-NEW",
        snapshot_ts: DateTime.utc_now()
      )

      :ok
    end

    test "run verification reports a state instead of crashing the LiveView", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "[data-role='build-change-banner'][data-verify-state='idle']")

      view |> element("button", "Run verification") |> render_click()

      # The click must be handled (the regression was a FunctionClauseError
      # killing the LiveView) and land in a real verify state: running,
      # or already classified when inline-Oban ran the refresh synchronously.
      assert has_element?(
               view,
               "[data-role='build-change-banner'][data-verify-state='running'], " <>
                 "[data-role='build-change-banner'][data-verify-state='fallback'], " <>
                 "[data-role='build-change-banner'][data-verify-state='failed'], " <>
                 "[data-role='build-change-banner'][data-verify-state='mtga_not_running']"
             )
    end

    test "acknowledging clears the banner", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert has_element?(view, "[data-role='build-change-banner']")

      view |> element("button", "Acknowledge") |> render_click()

      refute has_element?(view, "[data-role='build-change-banner']")
    end
  end

  describe "memory reading toggle" do
    test "is on by default and persists off when clicked", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      assert Scry2.LiveState.enabled?()

      view
      |> element("input[phx-click='toggle_live_polling']")
      |> render_click()

      assert Settings.get("live_match_polling_enabled") == false
      refute Scry2.LiveState.enabled?()
    end

    test "toggles back on after a second click", %{conn: conn} do
      Settings.put!("live_match_polling_enabled", false)
      {:ok, view, _html} = live(conn, ~p"/settings")

      view
      |> element("input[phx-click='toggle_live_polling']")
      |> render_click()

      assert Settings.get("live_match_polling_enabled") == true
      assert Scry2.LiveState.enabled?()
    end
  end

  describe "refresh_cron form" do
    test "saves a valid cron expression", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      open_edit(view, "refresh_cron")

      view
      |> form("form[phx-submit='save_refresh_cron']", value: "0 5 * * *")
      |> render_submit()

      assert Settings.get("cards_refresh_cron") == "0 5 * * *"
    end

    test "shows an error for an invalid expression", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      open_edit(view, "refresh_cron")

      view
      |> form("form[phx-submit='save_refresh_cron']", value: "not a cron")
      |> render_submit()

      assert has_element?(view, "p.text-error", "Invalid cron")
    end
  end

  defp open_edit(view, field) do
    view
    |> element("button[phx-click='start_edit'][phx-value-field='#{field}']")
    |> render_click()
  end
end
