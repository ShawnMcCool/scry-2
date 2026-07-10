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

    render_click(view, "toggle_import_panel")

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

  defmodule BrowseStub do
    @behaviour Scry2.NetDecking.Source
    @impl true
    def source_name, do: "stub-mtgo"
    @impl true
    def formats, do: ["standard"]
    @impl true
    def fetch, do: []

    @impl true
    def list_events("standard") do
      {:ok, [%{name: "Stub Challenge 32", date: ~D[2026-07-01], url: "https://stub/e1"}]}
    end

    @impl true
    def fetch_event("https://stub/e1") do
      {:ok,
       [
         %{
           name: "Stub Challenge 32 — p1",
           decklist_text: "Deck\n4 Lightning Bolt\n",
           source_url: "https://stub/e1",
           pilot: "p1",
           event_name: "Stub Challenge 32",
           event_date: ~D[2026-07-01],
           placement: 1,
           field_size: 32,
           wins: 7,
           losses: 1
         }
       ]}
    end
  end

  defmodule FailingBrowseStub do
    @behaviour Scry2.NetDecking.Source
    @impl true
    def source_name, do: "failing-stub"
    @impl true
    def formats, do: ["standard"]
    @impl true
    def fetch, do: []
    @impl true
    def list_events(_format), do: {:error, :unreachable}
    @impl true
    def fetch_event(_url), do: {:error, :unreachable}
  end

  defp put_sources(sources) do
    previous = Application.get_env(:scry_2, :netdecking_sources)
    Application.put_env(:scry_2, :netdecking_sources, sources)

    on_exit(fn ->
      if previous do
        Application.put_env(:scry_2, :netdecking_sources, previous)
      else
        Application.delete_env(:scry_2, :netdecking_sources)
      end
    end)
  end

  describe "import browser" do
    test "browse mode lists a source's events and imports the selected ones", %{conn: conn} do
      put_sources([BrowseStub])
      create_card(name: "Lightning Bolt", rarity: "rare")

      {:ok, view, _html} = live(conn, ~p"/netdecks")
      render_click(view, "toggle_import_panel")
      render_click(view, "import_mode", %{"mode" => "browse"})

      html = render_async(view)
      assert html =~ "Stub Challenge 32"

      render_click(view, "browse_toggle_event", %{"url" => "https://stub/e1"})
      render_click(view, "browse_import")
      html = render_async(view)

      assert [deck] = Scry2.NetDecking.list_decks()
      assert deck.pilot == "p1"
      assert deck.source_url == "https://stub/e1"
      # the event is now marked imported in the list
      assert html =~ "imported"
    end

    test "a failed event listing shows an inline error, not an empty list", %{conn: conn} do
      put_sources([FailingBrowseStub])

      {:ok, view, _html} = live(conn, ~p"/netdecks")
      render_click(view, "toggle_import_panel")
      render_click(view, "import_mode", %{"mode" => "browse"})

      html = render_async(view)
      assert html =~ "Couldn"
      assert html =~ "Retry"
    end

    test "auto-fetch toggle persists per source", %{conn: conn} do
      put_sources([BrowseStub])

      {:ok, view, _html} = live(conn, ~p"/netdecks")
      render_click(view, "toggle_import_panel")
      render_click(view, "import_mode", %{"mode" => "browse"})
      render_async(view)

      render_click(view, "toggle_auto_fetch", %{"source" => "stub-mtgo"})
      refute Scry2.NetDecking.auto_fetch_enabled?("stub-mtgo")

      render_click(view, "toggle_auto_fetch", %{"source" => "stub-mtgo"})
      assert Scry2.NetDecking.auto_fetch_enabled?("stub-mtgo")
    end
  end
end
