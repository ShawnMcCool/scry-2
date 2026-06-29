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
    assert render(view) =~ "Mono-White · Lightning Bolt"
    assert render(view) =~ "Buildable now"
  end

  test "catalog renders clustered deck tiles with labels", %{conn: conn} do
    bolt = create_card(name: "Lightning Bolt", rarity: "rare", color_identity: "R")
    create_card(name: "Mountain", rarity: "common", color_identity: "")
    create_collection_snapshot(entries: [{bolt.arena_id, 4}])

    {:ok, _} =
      Scry2.NetDecking.import_decklist(%{
        name: "Burn",
        source_name: "mtgo",
        decklist_text: "Deck\n4 Lightning Bolt\n16 Mountain\n"
      })

    {:ok, _view, html} = live(conn, ~p"/netdecks")
    assert html =~ "Mono-Red · Lightning Bolt"
  end

  test "import event adds a deck to the catalog", %{conn: conn} do
    create_card(name: "Lightning Bolt", rarity: "rare")
    {:ok, view, _html} = live(conn, ~p"/netdecks")

    view
    |> form("#netdeck-import",
      import: %{name: "Burn", archetype: "Aggro", decklist_text: "Deck\n4 Lightning Bolt\n"}
    )
    |> render_submit()

    assert render(view) =~ "Burn"
  end

  test "detail view lists the deck's cards and a copy button", %{conn: conn} do
    bolt = create_card(name: "Lightning Bolt", rarity: "rare")
    create_card(name: "Mountain", rarity: "common")
    create_collection_snapshot(entries: [{bolt.arena_id, 2}], wildcards_rare: 5)

    {:ok, deck} =
      Scry2.NetDecking.import_decklist(%{
        name: "Mono-Red",
        archetype: "Aggro",
        source_name: "manual",
        decklist_text: "Deck\n4 Lightning Bolt\n16 Mountain\n"
      })

    {:ok, _view, html} = live(conn, ~p"/netdecks/#{deck.id}")

    assert html =~ "Lightning Bolt"
    assert html =~ "Copy to MTGA"
    assert html =~ "Aggro"
  end

  test "unknown deck id redirects back to the catalog", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/netdecks"}}} = live(conn, ~p"/netdecks/999999")
  end

  test "Fetch now triggers a refresh and flashes", %{conn: conn} do
    # No sources → the inline worker is a no-op (no network), so we test the
    # trigger + flash, not source behaviour (covered in worker/source tests).
    previous = Application.get_env(:scry_2, :netdecking_sources)
    Application.put_env(:scry_2, :netdecking_sources, [])
    on_exit(fn -> Application.put_env(:scry_2, :netdecking_sources, previous) end)

    {:ok, view, _html} = live(conn, ~p"/netdecks")
    html = render_click(view, "fetch_now")

    assert html =~ "Fetching"
  end
end
