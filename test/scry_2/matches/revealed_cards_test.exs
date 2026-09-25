defmodule Scry2.Matches.RevealedCardsTest do
  @moduledoc """
  Accumulation rules for the revealed-cards read model (ADR-047).
  """
  use Scry2.DataCase, async: true

  alias Scry2.Matches

  @match "test-match-0001"

  defp reveal(attrs) do
    Matches.record_revealed_card!(
      Map.merge(
        %{mtga_match_id: @match, seat_id: 1, arena_id: 12_345, current_zone: "hand"},
        attrs
      )
    )
  end

  describe "record_revealed_card!/1" do
    test "records a first sighting" do
      reveal(%{turn_number: 3})

      assert [card] = Matches.revealed_cards(@match)
      assert card.arena_id == 12_345
      assert card.seat_id == 1
      assert card.current_zone == "hand"
      assert card.copies_seen == 1
      assert card.first_seen_turn == 3
      assert card.last_seen_turn == 3
    end

    test "a second sighting of the same card collapses onto one row" do
      reveal(%{turn_number: 3})
      reveal(%{turn_number: 5, current_zone: "graveyard"})

      assert [card] = Matches.revealed_cards(@match)
      assert card.copies_seen == 2
      assert card.current_zone == "graveyard", "latest zone wins"
      assert card.first_seen_turn == 3, "earliest turn is kept"
      assert card.last_seen_turn == 5
    end

    test "the same card under a different seat is a separate row" do
      reveal(%{seat_id: 1})
      reveal(%{seat_id: 2})

      assert length(Matches.revealed_cards(@match)) == 2
    end

    test "different cards are separate rows" do
      reveal(%{arena_id: 1})
      reveal(%{arena_id: 2})

      assert length(Matches.revealed_cards(@match)) == 2
    end

    test "rows are scoped to their match" do
      reveal(%{})
      reveal(%{mtga_match_id: "other-match"})

      assert [card] = Matches.revealed_cards(@match)
      assert card.mtga_match_id == @match
    end

    test "a nil zone does not erase a known zone" do
      # Bookkeeping transfers (limbo, pending) are real sightings but say
      # nothing about where the card now is.
      reveal(%{current_zone: "battlefield", turn_number: 1})
      reveal(%{current_zone: nil, turn_number: 2})

      assert [card] = Matches.revealed_cards(@match)
      assert card.current_zone == "battlefield"
      assert card.copies_seen == 2, "the sighting still counts"
    end

    test "tolerates a missing turn number" do
      reveal(%{turn_number: nil})

      assert [card] = Matches.revealed_cards(@match)
      assert card.first_seen_turn == nil
      assert card.copies_seen == 1
    end
  end

  describe "revealed_cards/1" do
    test "returns [] for a match with no reveals" do
      assert Matches.revealed_cards("no-such-match") == []
    end
  end

  describe "column storage types" do
    # Regression: pinned values inside a fragment carry no type, so Exqlite
    # encoded is_local as the TEXT "true"/"false" on the conflict path while
    # the insert path wrote SQLite's 0/1 — the same column held both.
    test "is_local is stored with one type on both insert and update paths" do
      reveal(%{arena_id: 1, is_local: true})
      # second sighting takes the ON CONFLICT path
      reveal(%{arena_id: 1, is_local: true})
      reveal(%{arena_id: 2, is_local: false})
      reveal(%{arena_id: 2, is_local: false})

      %{rows: rows} =
        Scry2.Repo.query!("SELECT DISTINCT typeof(is_local) FROM matches_revealed_cards")

      assert List.flatten(rows) == ["integer"]
    end

    test "is_local survives the round trip as a boolean" do
      reveal(%{arena_id: 1, is_local: false})
      reveal(%{arena_id: 1, is_local: false})

      assert [card] = Matches.revealed_cards(@match)
      assert card.is_local == false
    end

    test "a later nil does not erase a known role" do
      reveal(%{arena_id: 1, is_local: true})
      reveal(%{arena_id: 1, is_local: nil})

      assert [card] = Matches.revealed_cards(@match)
      assert card.is_local == true
    end
  end
end
