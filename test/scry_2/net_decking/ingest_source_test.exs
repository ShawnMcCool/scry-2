defmodule Scry2.NetDecking.IngestSourceTest do
  use Scry2.DataCase
  import Scry2.TestFactory

  alias Scry2.NetDecking
  alias Scry2.NetDecking.IngestSource

  defmodule StubSource do
    @behaviour Scry2.NetDecking.Source
    @impl true
    def fetch do
      [
        %{
          name: "Mono Red",
          source_name: "stub",
          decklist_text: "Deck\n4 Roaring Furnace (DFT) 1\n"
        },
        %{name: "Empty", source_name: "stub", decklist_text: ""}
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
end
