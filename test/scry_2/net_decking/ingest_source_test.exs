defmodule Scry2.NetDecking.IngestSourceTest do
  use Scry2.DataCase
  import Scry2.TestFactory

  alias Scry2.NetDecking
  alias Scry2.NetDecking.IngestSource

  defmodule StubSource do
    @behaviour Scry2.NetDecking.Source
    @impl true
    def source_name, do: "stub"

    @impl true
    def formats, do: []

    @impl true
    def fetch do
      [
        %{name: "Mono Red", decklist_text: "Deck\n4 Roaring Furnace (DFT) 1\n"},
        %{name: "Empty", decklist_text: ""}
      ]
    end
  end

  test "ingests every raw deck through the funnel and returns a summary" do
    create_card(name: "Roaring Furnace")

    summary = IngestSource.run(StubSource)

    assert summary.source == "stub"
    assert summary.ingested >= 1
    assert is_integer(summary.failed)
    assert NetDecking.list_decks() != []
  end

  defmodule BrowsableStubSource do
    @behaviour Scry2.NetDecking.Source
    @impl true
    def source_name, do: "browsable-stub"
    @impl true
    def formats, do: ["standard"]
    @impl true
    def fetch, do: []

    @impl true
    def list_events("standard"),
      do: {:ok, [%{name: "Stub Challenge", date: ~D[2026-07-01], url: "https://stub/event-1"}]}

    @impl true
    def fetch_event("https://stub/event-1") do
      {:ok,
       [
         %{
           name: "Stub Challenge — pilot1",
           decklist_text: "Deck\n4 Roaring Furnace (DFT) 1\n",
           source_url: "https://stub/event-1"
         }
       ]}
    end

    def fetch_event(_url), do: {:error, :not_found}
  end

  describe "run_event/2" do
    test "ingests one event's decks and returns a summary" do
      create_card(name: "Roaring Furnace")

      assert {:ok, summary} = IngestSource.run_event(BrowsableStubSource, "https://stub/event-1")

      assert summary.source == "browsable-stub"
      assert summary.ingested == 1
      assert summary.failed == 0

      [deck] = NetDecking.list_decks()
      assert deck.source_name == "browsable-stub"
      assert deck.source_url == "https://stub/event-1"
    end

    test "re-importing the same event creates no duplicate decks" do
      create_card(name: "Roaring Furnace")

      assert {:ok, _} = IngestSource.run_event(BrowsableStubSource, "https://stub/event-1")
      assert {:ok, _} = IngestSource.run_event(BrowsableStubSource, "https://stub/event-1")

      assert length(NetDecking.list_decks()) == 1
    end

    test "propagates a fetch failure" do
      assert {:error, :not_found} =
               IngestSource.run_event(BrowsableStubSource, "https://stub/missing")
    end
  end
end
