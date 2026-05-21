defmodule Scry2Web.DecksLiveTest do
  use Scry2Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Scry2.Decks
  alias Scry2.Settings
  alias Scry2.TestFactory, as: Factory

  setup do
    player = Factory.create_player()
    Settings.put!("active_player_id", player.id)
    %{player: player}
  end

  describe "/decks — status filter" do
    test "active view excludes archived decks", %{conn: conn} do
      active = Factory.create_deck(%{mtga_deck_id: "live-active", current_name: "ActiveName"})

      archived =
        Factory.create_deck(%{mtga_deck_id: "live-archived", current_name: "ArchivedName"})

      Factory.create_deck_match_result(%{deck: active, won: true})
      Factory.create_deck_match_result(%{deck: archived, won: true})
      Decks.update_deck_flags!(archived, %{archived: true})

      {:ok, _view, html} = live(conn, "/decks?status=active")

      assert html =~ "ActiveName"
      refute html =~ "ArchivedName"
    end

    test "archived view shows only archived decks with the badge", %{conn: conn} do
      _active = Factory.create_deck(%{mtga_deck_id: "live-active-2", current_name: "ActiveTwo"})

      archived =
        Factory.create_deck(%{mtga_deck_id: "live-archived-2", current_name: "ArchivedTwo"})

      Decks.update_deck_flags!(archived, %{archived: true})

      {:ok, _view, html} = live(conn, "/decks?status=archived")

      assert html =~ "ArchivedTwo"
      refute html =~ "ActiveTwo"
      assert html =~ "Archived"
    end
  end

  describe "/decks — star toggle" do
    test "clicking the star button flips the starred flag", %{conn: conn} do
      deck = Factory.create_deck(%{mtga_deck_id: "live-star", current_name: "ToStar"})

      {:ok, view, _html} = live(conn, "/decks?status=all")

      view
      |> element("button[phx-click=toggle_star][phx-value-deck-id=\"#{deck.mtga_deck_id}\"]")
      |> render_click()

      assert Decks.get_deck(deck.mtga_deck_id).starred == true
    end
  end

  describe "/decks/:id — export" do
    test "exposes the MTGA clipboard text via data-copy-text", %{conn: conn} do
      deck =
        Factory.create_deck(%{
          mtga_deck_id: "live-export",
          current_name: "ExportMe",
          current_main_deck: %{"cards" => [%{"arena_id" => 12_345, "count" => 4}]},
          current_sideboard: %{"cards" => []}
        })

      {:ok, _view, html} = live(conn, "/decks/#{deck.mtga_deck_id}")

      assert html =~ "Copy to MTGA"
      assert html =~ "data-copy-text"
      assert html =~ "Deck\n4 "
    end

    test "renders star and archive buttons on the deck detail page", %{conn: conn} do
      deck = Factory.create_deck(%{mtga_deck_id: "live-detail", current_name: "DetailDeck"})

      {:ok, view, _html} = live(conn, "/decks/#{deck.mtga_deck_id}")

      view
      |> element("button[phx-click=toggle_archived][phx-value-deck-id=\"#{deck.mtga_deck_id}\"]")
      |> render_click()

      assert Decks.get_deck(deck.mtga_deck_id).archived == true
    end
  end
end
