defmodule Scry2.NetDecking.ReingestUnresolvedTest do
  use Scry2.DataCase, async: true

  import Scry2.TestFactory
  alias Scry2.NetDecking.{Deck, IngestDecklist, ReingestUnresolved}
  alias Scry2.Repo

  @event_url "https://www.mtgo.com/decklist/standard-challenge-1"

  defp decklist(mountains), do: "Deck\n4 Lightning Bolt\n#{mountains} Mountain\n"

  # Ingest a deck while "Lightning Bolt" is missing from the card data, so it
  # lands as an unresolved reference — the state a card-data improvement later
  # fixes. `mountains` varies the resolved maindeck so distinct pilots produce
  # distinct rows (composition_hash keys off the resolved cards).
  defp seed_stale_deck(pilot, mountains) do
    create_card(name: "Mountain", rarity: "common")

    {:ok, deck} =
      IngestDecklist.run(%{
        name: "Challenge — #{pilot}",
        source_name: "mtgo",
        source_url: @event_url,
        pilot: pilot,
        decklist_text: decklist(mountains)
      })

    deck
  end

  # A fetcher that returns the event's decks with their full text, as the real
  # source would after the card data caught up. `pilots` maps pilot => mountains.
  defp fetch_event_stub(pilots) do
    fn @event_url ->
      raw =
        Enum.map(pilots, fn {pilot, mountains} ->
          %{name: "Challenge — #{pilot}", pilot: pilot, decklist_text: decklist(mountains)}
        end)

      {:ok, raw}
    end
  end

  test "re-resolves stale decks in place once the card data covers them" do
    stale = seed_stale_deck("venom01", 16)
    assert [%{"name" => "Lightning Bolt"}] = stale.unresolved_cards["cards"]

    # Card data now covers the previously-missing card.
    create_card(name: "Lightning Bolt", rarity: "rare")

    report =
      ReingestUnresolved.run(apply: true, fetch_event: fetch_event_stub(%{"venom01" => 16}))

    assert report.reingested == 1

    fixed = Repo.get!(Deck, stale.id)
    assert fixed.unresolved_cards["cards"] == []
    assert length(fixed.main_deck["cards"]) == 2
    assert Repo.aggregate(Deck, :count) == 1
  end

  test "dry run reports the plan without writing" do
    stale = seed_stale_deck("venom01", 16)
    create_card(name: "Lightning Bolt", rarity: "rare")

    report =
      ReingestUnresolved.run(apply: false, fetch_event: fetch_event_stub(%{"venom01" => 16}))

    assert report.would_reingest == 1
    assert report.reingested == 0

    unchanged = Repo.get!(Deck, stale.id)
    assert [%{"name" => "Lightning Bolt"}] = unchanged.unresolved_cards["cards"]
  end

  test "falls back to name match when the stored deck has no pilot" do
    # Older MTGO ingests captured the pilot only in the deck name, not the
    # pilot field — so pilot matching misses and name matching must catch it.
    create_card(name: "Mountain", rarity: "common")

    {:ok, stale} =
      IngestDecklist.run(%{
        name: "Standard Challenge — medvedev",
        source_name: "mtgo",
        source_url: @event_url,
        pilot: nil,
        decklist_text: decklist(16)
      })

    assert stale.pilot == nil
    create_card(name: "Lightning Bolt", rarity: "rare")

    fetch =
      fn @event_url ->
        {:ok,
         [
           %{
             name: "Standard Challenge — medvedev",
             pilot: "medvedev",
             decklist_text: decklist(16)
           }
         ]}
      end

    report = ReingestUnresolved.run(apply: true, fetch_event: fetch)
    assert report.reingested == 1
    assert report.unmatched == 0

    fixed = Repo.get!(Deck, stale.id)
    assert fixed.unresolved_cards["cards"] == []
    # Re-ingest also backfills the previously-missing pilot.
    assert fixed.pilot == "medvedev"
  end

  test "only: restricts to the given deck ids" do
    keep = seed_stale_deck("venom01", 16)
    skip = seed_stale_deck("goblin02", 15)
    refute keep.id == skip.id
    create_card(name: "Lightning Bolt", rarity: "rare")

    ReingestUnresolved.run(
      apply: true,
      only: [keep.id],
      fetch_event: fetch_event_stub(%{"venom01" => 16, "goblin02" => 15})
    )

    assert Repo.get!(Deck, keep.id).unresolved_cards["cards"] == []
    assert [%{"name" => "Lightning Bolt"}] = Repo.get!(Deck, skip.id).unresolved_cards["cards"]
  end
end
