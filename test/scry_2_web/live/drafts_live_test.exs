defmodule Scry2Web.DraftsLiveTest do
  use Scry2Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Scry2.Settings
  alias Scry2.TestFactory, as: Factory

  defp setup_player(_conn) do
    player = Factory.create_player(%{screen_name: "DraftTester"})
    Settings.put!("active_player_id", player.id)
    player.id
  end

  describe "list view (/drafts)" do
    test "shows stat cards", %{conn: conn} do
      player_id = setup_player(conn)

      Factory.create_draft(%{
        player_id: player_id,
        wins: 7,
        losses: 0,
        completed_at: DateTime.utc_now(:second),
        format: "quick_draft",
        set_code: "FDN"
      })

      Factory.create_draft(%{
        player_id: player_id,
        wins: 3,
        losses: 3,
        completed_at: DateTime.utc_now(:second),
        format: "premier_draft",
        set_code: "FDN"
      })

      {:ok, view, _html} = live(conn, ~p"/drafts")

      assert has_element?(view, "[data-stat='total-drafts']", "2")
      assert has_element?(view, "[data-stat='trophies']", "1")
    end

    test "shows format filter chips", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/drafts")
      assert has_element?(view, "[data-filter='format']")
    end

    test "filters list by format", %{conn: conn} do
      player_id = setup_player(conn)

      Factory.create_draft(%{
        player_id: player_id,
        format: "quick_draft",
        set_code: "FDN"
      })

      Factory.create_draft(%{
        player_id: player_id,
        format: "premier_draft",
        set_code: "FDN"
      })

      {:ok, view, _html} = live(conn, ~p"/drafts?format=quick_draft")

      assert has_element?(view, "tr[data-format='quick_draft']")
      refute has_element?(view, "tr[data-format='premier_draft']")
    end
  end

  describe "detail -- picks tab" do
    test "renders pack sections with picked card highlighted", %{conn: conn} do
      player_id = setup_player(conn)

      draft =
        Factory.create_draft(%{
          player_id: player_id,
          format: "quick_draft",
          set_code: "FDN"
        })

      Factory.create_pick(%{
        draft: draft,
        pack_number: 1,
        pick_number: 1,
        picked_arena_id: 91_234,
        pack_arena_ids: %{"cards" => [91_234, 91_235]}
      })

      {:ok, view, _html} = live(conn, ~p"/drafts/#{draft.id}?tab=picks")

      assert has_element?(view, "[data-pack='1-1']")
      assert has_element?(view, "[data-picked='91234']")
    end
  end

  describe "detail -- deck tab" do
    test "shows submitted decks section", %{conn: conn} do
      player_id = setup_player(conn)
      event_name = "QuickDraft_FDN_20260401"

      Factory.create_draft(%{
        player_id: player_id,
        mtga_draft_id: event_name,
        event_name: event_name,
        format: "quick_draft",
        set_code: "FDN"
      })

      Factory.create_match(%{
        player_id: player_id,
        event_name: event_name,
        mtga_deck_id: "deck-abc",
        deck_name: "UR Control"
      })

      # The draft might have a different id; let's fetch by event_name
      draft = Scry2.Drafts.get_by_event_name(event_name, player_id)

      {:ok, view, _html} = live(conn, ~p"/drafts/#{draft.id}?tab=deck")

      assert has_element?(view, "[data-section='submitted-decks']")
      assert has_element?(view, "[data-deck='deck-abc']")
    end

    test "shows pool section when card_pool_arena_ids present", %{conn: conn} do
      player_id = setup_player(conn)

      draft =
        Factory.create_draft(%{
          player_id: player_id,
          card_pool_arena_ids: %{"ids" => [91_234]},
          format: "quick_draft",
          set_code: "FDN"
        })

      {:ok, view, _html} = live(conn, ~p"/drafts/#{draft.id}?tab=deck")

      assert has_element?(view, "[data-section='draft-pool']")
    end
  end

  describe "detail -- tab navigation" do
    test "each tab renders its own section and not the others", %{conn: conn} do
      player_id = setup_player(conn)

      draft =
        Factory.create_draft(%{
          player_id: player_id,
          format: "quick_draft",
          set_code: "FDN"
        })

      Factory.create_pick(%{
        draft: draft,
        pack_number: 1,
        pick_number: 1,
        picked_arena_id: 91_234,
        pack_arena_ids: %{"cards" => [91_234, 91_235]}
      })

      {:ok, view, _html} = live(conn, ~p"/drafts/#{draft.id}?tab=picks")
      assert has_element?(view, "[data-pack='1-1']")
      refute has_element?(view, "[data-section='draft-pool']")

      {:ok, view, _html} = live(conn, ~p"/drafts/#{draft.id}?tab=deck")
      assert has_element?(view, "[data-section='draft-pool']")
      refute has_element?(view, "[data-pack='1-1']")

      {:ok, view, _html} = live(conn, ~p"/drafts/#{draft.id}?tab=matches")
      refute has_element?(view, "[data-section='draft-pool']")
      refute has_element?(view, "[data-pack='1-1']")
    end
  end

  describe "detail -- matches tab" do
    test "shows matches with deck link", %{conn: conn} do
      player_id = setup_player(conn)
      event_name = "QuickDraft_FDN_20260401"

      draft =
        Factory.create_draft(%{
          player_id: player_id,
          mtga_draft_id: event_name,
          event_name: event_name,
          format: "quick_draft",
          set_code: "FDN"
        })

      match =
        Factory.create_match(%{
          player_id: player_id,
          event_name: event_name,
          won: true,
          opponent_screen_name: "StormCrow88",
          mtga_deck_id: "deck-abc",
          deck_name: "UR Control"
        })

      {:ok, view, _html} = live(conn, ~p"/drafts/#{draft.id}?tab=matches")

      assert has_element?(view, "[data-match='#{match.id}']")
      assert has_element?(view, "[data-deck-link='deck-abc']")
      assert render(view) =~ "StormCrow88"
    end
  end
end
