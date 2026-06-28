defmodule Scry2Web.NetdecksLiveTest do
  use Scry2Web.ConnCase

  import Phoenix.LiveViewTest
  import Scry2.TestFactory

  test "renders the catalog grouped by status", %{conn: conn} do
    bolt = create_card(name: "Lightning Bolt", rarity: "rare")
    create_card(name: "Mountain", rarity: "common")
    create_collection_snapshot(entries: [{bolt.arena_id, 4}])

    {:ok, _} =
      Scry2.NetDecking.import_decklist(%{
        name: "Mono-Red",
        source_name: "manual",
        decklist_text: "Deck\n4 Lightning Bolt\n16 Mountain\n"
      })

    {:ok, view, _html} = live(conn, ~p"/netdecks")
    assert render(view) =~ "Mono-Red"
    assert render(view) =~ "Buildable"
  end

  test "import event adds a deck to the catalog", %{conn: conn} do
    create_card(name: "Lightning Bolt", rarity: "rare")
    {:ok, view, _html} = live(conn, ~p"/netdecks")

    view
    |> form("#netdeck-import", import: %{name: "Burn", decklist_text: "Deck\n4 Lightning Bolt\n"})
    |> render_submit()

    assert render(view) =~ "Burn"
  end
end
