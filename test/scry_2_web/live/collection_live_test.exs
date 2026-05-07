defmodule Scry2Web.CollectionLiveTest do
  use Scry2Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Scry2.Collection
  alias Scry2.MtgaMemory.TestBackend
  alias Scry2.Settings
  alias Scry2.TestFactory, as: Factory

  setup do
    player = Factory.create_player(%{screen_name: "CollectionTester"})
    Settings.put!("active_player_id", player.id)
    Collection.disable_reader!()
    TestBackend.clear_fixture()
    %{player_id: player.id}
  end

  test "disabled view shows the enable banner", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/collection")
    assert has_element?(view, "[data-role='collection-disabled']")
    assert has_element?(view, "button", "Enable memory reader")
  end

  test "enabling flips to the empty enabled view", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/collection")

    view |> element("button", "Enable memory reader") |> render_click()

    assert has_element?(view, "[data-role='collection-enabled']")
    assert has_element?(view, "[data-role='no-snapshot']")
    assert Collection.reader_enabled?()
  end

  test "disabling from the enabled view returns to the banner", %{conn: conn} do
    Collection.enable_reader!()
    {:ok, view, _html} = live(conn, ~p"/collection")

    view |> element("button", "Disable reader") |> render_click()

    assert has_element?(view, "[data-role='collection-disabled']")
    refute Collection.reader_enabled?()
  end

  test "renders the holding summary when a snapshot exists", %{conn: conn} do
    Collection.enable_reader!()
    Factory.create_collection_snapshot(entries: [{30_001, 2}, {91_234, 1}])

    {:ok, view, _html} = live(conn, ~p"/collection")

    assert has_element?(view, "[data-role='holding-summary']")
    # 2 entries → 2 unique cards, 3 total copies. Cards may not be in
    # cards_cards yet for the synthetic arena_ids, so the holdings list
    # could be empty in that case — the summary still renders with zeroes.
    assert has_element?(view, "[data-stat='unique']")
    assert has_element?(view, "[data-stat='copies']")
  end

  test "shows reader status toolbar when enabled", %{conn: conn} do
    Collection.enable_reader!()
    {:ok, view, _html} = live(conn, ~p"/collection")
    assert has_element?(view, "[data-role='reader-status']")
  end

  test "shows the disabled banner data-role when reader is off", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/collection")
    assert has_element?(view, "[data-role='collection-disabled']")
  end

  test "manual refresh with no MTGA surfaces an error", %{conn: conn} do
    Collection.enable_reader!()
    TestBackend.set_fixture(processes: [])

    {:ok, view, _html} = live(conn, ~p"/collection")

    view |> element("button", "Refresh now") |> render_click()

    assert has_element?(view, "[data-role='collection-error']")
  end
end
