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

  describe "reader-health pill" do
    test "renders an OK pill when the latest snapshot is a fresh walker read", %{conn: conn} do
      Collection.enable_reader!()

      Factory.create_collection_snapshot(
        entries: [{30_001, 1}],
        reader_confidence: "walker",
        mtga_build_hint: "BUILD-CURRENT",
        snapshot_ts: DateTime.utc_now()
      )

      {:ok, view, _html} = live(conn, ~p"/collection")

      assert has_element?(view, "[data-role='reader-health-pill'][data-tone='ok']")
    end

    test "renders a warn pill when the latest snapshot used the fallback scanner",
         %{conn: conn} do
      Collection.enable_reader!()

      Factory.create_collection_snapshot(
        entries: [{30_001, 1}],
        reader_confidence: "fallback_scan",
        snapshot_ts: DateTime.utc_now()
      )

      {:ok, view, _html} = live(conn, ~p"/collection")

      assert has_element?(view, "[data-role='reader-health-pill'][data-tone='warn']")
    end
  end

  describe "build-change banner verify flow" do
    setup do
      Collection.enable_reader!()
      Settings.put!("collection.acknowledged_build_hint", "BUILD-OLD")

      Factory.create_collection_snapshot(
        entries: [{30_001, 1}],
        reader_confidence: "walker",
        mtga_build_hint: "BUILD-NEW",
        snapshot_ts: DateTime.utc_now()
      )

      :ok
    end

    test "build-change banner is rendered with a Run verification button when not auto-verified",
         %{conn: conn} do
      # Override the setup snapshot with a fallback-scan one so the banner
      # stays in :idle (auto-verification only kicks in for walker confidence).
      Settings.put!("collection.acknowledged_build_hint", "BUILD-OLDER-STILL")

      Factory.create_collection_snapshot(
        entries: [{30_001, 1}],
        reader_confidence: "fallback_scan",
        mtga_build_hint: "BUILD-NEW",
        snapshot_ts: DateTime.utc_now()
      )

      {:ok, view, _html} = live(conn, ~p"/collection")

      assert has_element?(view, "[data-role='build-change-banner']")
      assert has_element?(view, "button", "Run verification")
    end

    test "implicit verification: walker-confidence snapshot on the new build pre-resolves to OK",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/collection")

      assert has_element?(view, "[data-role='build-change-banner'][data-verify-state='ok']")
      assert has_element?(view, "button", "Acknowledge")
    end

    test "verify_build_change handler enqueues a refresh and shows the running state",
         %{conn: conn} do
      Settings.put!("collection.acknowledged_build_hint", "BUILD-OLDER")

      Factory.create_collection_snapshot(
        entries: [{30_001, 1}],
        reader_confidence: "fallback_scan",
        mtga_build_hint: "BUILD-NEW",
        snapshot_ts: DateTime.utc_now()
      )

      {:ok, view, _html} = live(conn, ~p"/collection")

      assert has_element?(view, "[data-role='build-change-banner'][data-verify-state='idle']")

      view |> element("button", "Run verification") |> render_click()

      # After click, either running (async-Oban) or already classified (inline-Oban
      # ran the job synchronously). Inline-Oban in tests will land a fallback snapshot,
      # which the LiveView classifies as :fallback.
      assert has_element?(
               view,
               "[data-role='build-change-banner'][data-verify-state='running'], [data-role='build-change-banner'][data-verify-state='fallback']"
             )
    end

    test "acknowledging clears the banner", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/collection")

      assert has_element?(view, "[data-role='build-change-banner']")

      view |> element("button", "Acknowledge") |> render_click()

      refute has_element?(view, "[data-role='build-change-banner']")
    end
  end

  describe "rendered_arena_ids/2" do
    alias Scry2.Collection.{CraftPlan, Holding}
    alias Scry2Web.CollectionLive

    defp holding(arena_id) do
      %Holding{arena_id: arena_id, count: 1, card: nil, copies_to_playset: 3}
    end

    defp craft_plan(playset_arena_ids) do
      %CraftPlan{
        incomplete_playsets:
          Enum.map(playset_arena_ids, &%{holding: holding(&1), copies_needed: 4}),
        wildcards_owned: %{},
        wildcards_needed_by_rarity: %{}
      }
    end

    test "unions visible browser holdings with craft-plan cards, de-duped" do
      browser = [holding(1), holding(2)]

      assert browser |> CollectionLive.rendered_arena_ids(craft_plan([2, 3])) |> Enum.sort() ==
               [1, 2, 3]
    end

    test "handles an empty craft plan" do
      assert CollectionLive.rendered_arena_ids([holding(7)], craft_plan([])) == [7]
    end
  end
end
