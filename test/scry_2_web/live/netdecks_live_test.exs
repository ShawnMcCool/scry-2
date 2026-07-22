defmodule Scry2Web.NetdecksLiveTest do
  use Scry2Web.ConnCase

  import Phoenix.LiveViewTest
  import Scry2.TestFactory

  test "renders the catalog grouped by status", %{conn: conn} do
    bolt = create_card(name: "Lightning Bolt", rarity: "rare")
    create_card(name: "Mountain", rarity: "common", is_land: true, types: "Land")
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

  test "catalog renders archetype rows with labels", %{conn: conn} do
    bolt = create_card(name: "Lightning Bolt", rarity: "rare", color_identity: "R")

    create_card(
      name: "Mountain",
      rarity: "common",
      color_identity: "",
      is_land: true,
      types: "Land"
    )

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

  test "detail view renders the variant matrix when the cluster has variants", %{conn: conn} do
    create_card(name: "Lightning Bolt", rarity: "rare")
    create_card(name: "Shock", rarity: "common")
    create_card(name: "Mountain", rarity: "common", is_land: true, types: "Land")

    {:ok, viewed} =
      Scry2.NetDecking.import_decklist(%{
        name: "Mono-Red A",
        source_name: "manual",
        decklist_text: "Deck\n4 Lightning Bolt\n4 Shock\n16 Mountain\n"
      })

    {:ok, _variant} =
      Scry2.NetDecking.import_decklist(%{
        name: "Mono-Red B",
        source_name: "manual",
        decklist_text: "Deck\n4 Lightning Bolt\n3 Shock\n17 Mountain\n"
      })

    {:ok, view, html} = live(conn, ~p"/netdecks/#{viewed.id}")

    assert html =~ "Variant matrix"

    # Column heads patch between variants; the matrix re-anchors in place.
    variant_html =
      view
      |> element("#variant-matrix a", "Mono-Red B")
      |> render_click()

    assert variant_html =~ "Variant matrix"

    variant = Enum.find(Scry2.NetDecking.list_decks(), &(&1.name == "Mono-Red B"))
    assert_patch(view, ~p"/netdecks/#{variant.id}")
  end

  test "unknown deck id redirects back to the catalog", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/netdecks"}}} = live(conn, ~p"/netdecks/999999")
  end

  test "tier headers state their ordering rule", %{conn: conn} do
    create_card(name: "Lightning Bolt", rarity: "rare")

    {:ok, _} =
      Scry2.NetDecking.import_decklist(%{
        name: "Burn",
        source_name: "manual",
        decklist_text: "Deck\n4 Lightning Bolt\n"
      })

    {:ok, _view, html} = live(conn, ~p"/netdecks")
    assert html =~ "ordered by best finish"
    assert html =~ "ordered by cheapest build"
  end

  test "a single-build archetype row links straight to that build's deck page", %{conn: conn} do
    bolt = create_card(name: "Lightning Bolt", rarity: "rare", color_identity: "R")
    create_collection_snapshot(entries: [{bolt.arena_id, 4}])

    {:ok, deck} =
      Scry2.NetDecking.import_decklist(%{
        name: "Challenge — winner",
        source_name: "mtgo",
        decklist_text: "Deck\n4 Lightning Bolt\n",
        pilot: "winner",
        event_name: "Standard Challenge 32",
        event_date: ~D[2026-07-05],
        placement: 1,
        field_size: 32,
        wins: 7,
        losses: 1
      })

    {:ok, view, _html} = live(conn, ~p"/netdecks")

    # One build → the tile skips the archetype screen and links to the deck.
    view
    |> element(~s{a[href="/netdecks/#{deck.id}"]}, "Mono-Red")
    |> render_click()

    assert_patch(view, ~p"/netdecks/#{deck.id}")
    assert render(view) =~ "Copy to MTGA"
  end

  test "an archetype variant row opens that list's deck detail", %{conn: conn} do
    create_card(name: "Lightning Bolt", rarity: "rare", color_identity: "R")

    {:ok, deck} =
      Scry2.NetDecking.import_decklist(%{
        name: "Burn",
        source_name: "manual",
        decklist_text: "Deck\n4 Lightning Bolt\n"
      })

    catalog = Scry2.NetDecking.catalog()
    [group] = catalog.buildable ++ catalog.craftable ++ catalog.short

    {:ok, view, html} = live(conn, ~p"/netdecks/archetype/#{group.slug}")
    assert html =~ group.label

    view
    |> element(~s{a[href="/netdecks/#{deck.id}"]})
    |> render_click()

    assert_patch(view, ~p"/netdecks/#{deck.id}")
    assert render(view) =~ "Copy to MTGA"
  end

  test "the archetype screen shows the core summary and a variant's deltas", %{conn: conn} do
    create_card(name: "Lightning Bolt", rarity: "rare", color_identity: "R")
    create_card(name: "Goblin Raider", rarity: "common", color_identity: "R")
    create_card(name: "Shock Bolt", rarity: "common", color_identity: "R")
    create_card(name: "Grizzly Bear", rarity: "rare", color_identity: "G")

    {:ok, _} =
      Scry2.NetDecking.import_decklist(%{
        name: "Red A",
        source_name: "mtgo",
        decklist_text: "Deck\n4 Lightning Bolt\n4 Goblin Raider\n4 Shock Bolt\n"
      })

    {:ok, _} =
      Scry2.NetDecking.import_decklist(%{
        name: "Red B",
        source_name: "mtgo",
        decklist_text: "Deck\n4 Lightning Bolt\n4 Goblin Raider\n4 Shock Bolt\n1 Grizzly Bear\n"
      })

    catalog = Scry2.NetDecking.catalog()
    [group] = catalog.buildable ++ catalog.craftable ++ catalog.short

    {:ok, _view, html} = live(conn, ~p"/netdecks/archetype/#{group.slug}")

    assert html =~ "core — in most lists"
    # The representative (Bear-less) list cuts the core's Bear: −1 chip.
    assert html =~ "Grizzly Bear −1 vs. the core"
  end

  test "the archetype core renders through the standard composition controls", %{conn: conn} do
    create_card(name: "Lightning Bolt", rarity: "rare", color_identity: "R")

    {:ok, _} =
      Scry2.NetDecking.import_decklist(%{
        name: "Red A",
        source_name: "mtgo",
        decklist_text: "Deck\n4 Lightning Bolt\n"
      })

    catalog = Scry2.NetDecking.catalog()
    [group] = catalog.buildable ++ catalog.craftable ++ catalog.short

    {:ok, view, _html} = live(conn, ~p"/netdecks/archetype/#{group.slug}")

    # The composition's display-mode control is present; switching to the
    # text list re-renders the core through the text section.
    view
    |> element(~s{button[phx-value-field="display_mode"][phx-value-to="text"]}, "Text")
    |> render_click()

    assert render(view) =~ "Lightning Bolt"
  end

  test "unknown archetype slug redirects back to the catalog", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/netdecks"}}} =
             live(conn, ~p"/netdecks/archetype/never-heard-of-it")
  end

  describe "recent view (UIDR-018)" do
    test "the Recent tab lists decks ordered by fetched_at, newest first", %{conn: conn} do
      create_card(name: "Lightning Bolt", rarity: "rare")

      {:ok, older} =
        Scry2.NetDecking.import_decklist(%{
          name: "Older Deck",
          source_name: "manual",
          decklist_text: "Deck\n1 Lightning Bolt\n"
        })

      {:ok, newer} =
        Scry2.NetDecking.import_decklist(%{
          name: "Newer Deck",
          source_name: "manual",
          decklist_text: "Deck\n2 Lightning Bolt\n"
        })

      pin_fetched_at(older, ~U[2026-07-01 00:00:00.000000Z])
      pin_fetched_at(newer, ~U[2026-07-10 00:00:00.000000Z])

      {:ok, view, _html} = live(conn, ~p"/netdecks")

      view
      |> element(~s{a[href^="/netdecks?"]}, "Recent")
      |> render_click()

      assert_patch(view, ~p"/netdecks?view=recent")
      html = render(view)

      assert position_of(html, "Newer Deck") < position_of(html, "Older Deck")
    end

    test "By status is the default with no view param", %{conn: conn} do
      create_card(name: "Lightning Bolt", rarity: "rare")

      {:ok, _} =
        Scry2.NetDecking.import_decklist(%{
          name: "Burn",
          source_name: "manual",
          decklist_text: "Deck\n4 Lightning Bolt\n"
        })

      {:ok, _view, html} = live(conn, ~p"/netdecks")
      assert html =~ "Buildable now"
    end

    test "clicking a recent row opens that deck's detail", %{conn: conn} do
      create_card(name: "Lightning Bolt", rarity: "rare")

      {:ok, deck} =
        Scry2.NetDecking.import_decklist(%{
          name: "Burn",
          source_name: "manual",
          decklist_text: "Deck\n4 Lightning Bolt\n"
        })

      {:ok, _} =
        Scry2.NetDecking.import_decklist(%{
          name: "Also Burn",
          source_name: "manual",
          decklist_text: "Deck\n3 Lightning Bolt\n"
        })

      {:ok, view, html} = live(conn, ~p"/netdecks?view=recent")

      # The Recent tab is genuinely rendering (both decks present, unlike the
      # tiered view which would cluster/label them) before we click through.
      assert html =~ "Burn"
      assert html =~ "Also Burn"

      view
      |> element(~s{a[href="/netdecks/#{deck.id}"]})
      |> render_click()

      assert_patch(view, ~p"/netdecks/#{deck.id}")
      assert render(view) =~ "Copy to MTGA"
    end

    test "an empty catalog shows the same empty state on Recent", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/netdecks?view=recent")
      assert html =~ "No decks yet"
    end

    test "a snapshot_saved rescore refreshes data without reordering the recent list", %{
      conn: conn
    } do
      bolt = create_card(name: "Lightning Bolt", rarity: "rare", color_identity: "R")

      {:ok, older} =
        Scry2.NetDecking.import_decklist(%{
          name: "Older Deck",
          source_name: "manual",
          decklist_text: "Deck\n1 Lightning Bolt\n"
        })

      {:ok, newer} =
        Scry2.NetDecking.import_decklist(%{
          name: "Newer Deck",
          source_name: "manual",
          decklist_text: "Deck\n2 Lightning Bolt\n"
        })

      pin_fetched_at(older, ~U[2026-07-01 00:00:00.000000Z])
      pin_fetched_at(newer, ~U[2026-07-10 00:00:00.000000Z])

      {:ok, view, _html} = live(conn, ~p"/netdecks?view=recent")
      html = render(view)
      assert position_of(html, "Newer Deck") < position_of(html, "Older Deck")

      create_collection_snapshot(entries: [{bolt.arena_id, 4}])
      Scry2.Topics.broadcast(Scry2.Topics.collection_snapshots(), {:snapshot_saved, %{}})
      # Mailbox drain (ADR-009 exception): ensures the broadcast above has been
      # handled before asserting, without inspecting GenServer-internal state.
      :sys.get_state(view.pid)

      html = render(view)
      assert position_of(html, "Newer Deck") < position_of(html, "Older Deck")
    end
  end

  defp position_of(html, text) do
    {index, _length} = :binary.match(html, text)
    index
  end

  defp pin_fetched_at(deck, fetched_at) do
    deck
    |> Ecto.Changeset.change(fetched_at: fetched_at)
    |> Scry2.Repo.update!()
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
