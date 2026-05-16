defmodule Scry2Web.SetDetailLiveTest do
  use Scry2Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Scry2.Cards.SetRoster
  alias Scry2.Collection
  alias Scry2.MtgaMemory.TestBackend
  alias Scry2.Settings
  alias Scry2.TestFactory, as: Factory

  setup do
    player = Factory.create_player(%{screen_name: "SetDetailTester"})
    Settings.put!("active_player_id", player.id)
    Collection.disable_reader!()
    TestBackend.clear_fixture()
    %{player_id: player.id}
  end

  defp create_blb_set_with_cards do
    set = Factory.create_set(%{code: "BLB", name: "Bloomburrow", released_at: ~D[2024-08-02]})

    cards =
      for {arena_id, rarity} <- [
            {30_001, "mythic"},
            {30_002, "mythic"},
            {30_003, "rare"},
            {30_004, "rare"},
            {30_005, "uncommon"},
            {30_006, "common"}
          ] do
        # Unique name per arena_id so SetCompletion's name-based rollup
        # treats every fixture card as a distinct entry.
        Factory.create_card(%{
          arena_id: arena_id,
          set_id: set.id,
          rarity: rarity,
          name: "Test Card #{arena_id}",
          is_booster: true
        })
      end

    SetRoster.refresh()
    {set, cards}
  end

  test "disabled view shows the enable banner", %{conn: conn} do
    Factory.create_set(%{code: "BLB", name: "Bloomburrow"})
    SetRoster.refresh()

    {:ok, view, _html} = live(conn, ~p"/collection/sets/BLB")

    assert has_element?(view, "[data-role='collection-disabled']")
  end

  test "set-not-found message renders when the code is unknown", %{conn: conn} do
    Collection.enable_reader!()

    {:ok, view, html} = live(conn, ~p"/collection/sets/NOPE")

    assert has_element?(view, "[data-role='set-not-found']")
    assert html =~ "NOPE"
  end

  test "with snapshot, renders summary and gap list", %{conn: conn} do
    {set, _cards} = create_blb_set_with_cards()
    Collection.enable_reader!()

    # Snapshot: 4 of #30_001 (complete mythic playset), 2 of #30_003 (partial rare),
    # nothing else. Other set cards (30_002, 30_004, 30_005, 30_006) are missing.
    Factory.create_collection_snapshot(entries: [{30_001, 4}, {30_003, 2}])

    {:ok, view, _html} = live(conn, ~p"/collection/sets/#{set.code}")

    assert has_element?(view, "[data-role='set-detail']")
    assert has_element?(view, "[data-role='set-summary']")
    assert has_element?(view, "[data-stat='missing']", "4")
    assert has_element?(view, "[data-stat='partial']", "1")
    assert has_element?(view, "[data-stat='complete']", "1")

    assert has_element?(view, "[data-role='gap-list']")
    # All four gap rarities should have at least one section since each
    # rarity has at least one missing or partial card in the fixture.
    assert has_element?(view, "[data-role='gap-section'][data-rarity='mythic']")
    assert has_element?(view, "[data-role='gap-section'][data-rarity='rare']")
    assert has_element?(view, "[data-role='gap-section'][data-rarity='uncommon']")
    assert has_element?(view, "[data-role='gap-section'][data-rarity='common']")
  end

  test "no-snapshot empty state when reader is on but no data yet", %{conn: conn} do
    {set, _cards} = create_blb_set_with_cards()
    Collection.enable_reader!()

    {:ok, view, _html} = live(conn, ~p"/collection/sets/#{set.code}")

    assert has_element?(view, "[data-role='no-snapshot']")
  end

  test "pick_set navigates to the chosen set", %{conn: conn} do
    {blb, _} = create_blb_set_with_cards()

    other = Factory.create_set(%{code: "DSK", name: "Duskmourn", released_at: ~D[2024-09-27]})

    Factory.create_card(%{
      arena_id: 31_001,
      set_id: other.id,
      rarity: "rare",
      is_booster: true
    })

    SetRoster.refresh()

    Collection.enable_reader!()

    {:ok, view, _html} = live(conn, ~p"/collection/sets/#{blb.code}")

    assert {:error, {:live_redirect, %{to: "/collection/sets/DSK"}}} =
             view
             |> form("[data-role='set-picker']", code: "DSK")
             |> render_change()
  end

  test "all-complete banner appears when every card is at full playset", %{conn: conn} do
    {set, _cards} = create_blb_set_with_cards()
    Collection.enable_reader!()

    # 4 copies of every booster card → every card is complete.
    entries =
      for arena_id <- 30_001..30_006 do
        {arena_id, 4}
      end

    Factory.create_collection_snapshot(entries: entries)

    {:ok, view, _html} = live(conn, ~p"/collection/sets/#{set.code}")

    assert has_element?(view, "[data-role='all-complete']")
    assert has_element?(view, "[data-stat='complete']", "6")
    assert has_element?(view, "[data-stat='missing']", "0")
    assert has_element?(view, "[data-stat='partial']", "0")
  end
end
