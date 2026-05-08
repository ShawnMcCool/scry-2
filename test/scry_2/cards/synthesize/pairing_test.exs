defmodule Scry2.Cards.Synthesize.PairingTest do
  @moduledoc """
  Tests for the `(set_code, collector_number)`-primary join used by the
  synthesizer (ADR-038). Pure: no DB.
  """

  use ExUnit.Case, async: true

  alias Scry2.Cards.Synthesize.Pairing
  alias Scry2.TestFactory

  describe "for_mtga/2" do
    test "matches by (upcase(set_code), collector_number) when present in the index" do
      mtga = TestFactory.build_mtga_card(expansion_code: "SOS", collector_number: "001")
      scryfall = TestFactory.build_scryfall_card(set_code: "SOS", collector_number: "001")

      index = %{{"SOS", "001"} => scryfall}

      assert Pairing.for_mtga(mtga, index) == scryfall
    end

    test "regression: matches when Scryfall row has arena_id=nil (the SOS/TMT/TLA case)" do
      mtga =
        TestFactory.build_mtga_card(
          arena_id: 91_500,
          expansion_code: "SOS",
          collector_number: "042"
        )

      scryfall =
        TestFactory.build_scryfall_card(
          arena_id: nil,
          set_code: "SOS",
          collector_number: "042",
          name: "From Scryfall"
        )

      index = %{{"SOS", "042"} => scryfall}

      result = Pairing.for_mtga(mtga, index)
      assert result.name == "From Scryfall"
      # Arena_id from Scryfall is nil — that's the whole point. The match
      # is by (set, number), not by arena_id.
      assert is_nil(result.arena_id)
    end

    test "returns nil for tokens regardless of (set, number) match" do
      # MTGA's 'Copy' token at SOS#1 would otherwise match the parent
      # card 'The Dawning Archaic' at SOS#1.
      token =
        TestFactory.build_mtga_card(
          expansion_code: "SOS",
          collector_number: "001",
          is_token: true
        )

      parent =
        TestFactory.build_scryfall_card(
          set_code: "SOS",
          collector_number: "001",
          name: "The Dawning Archaic"
        )

      index = %{{"SOS", "001"} => parent}

      assert Pairing.for_mtga(token, index) == nil
    end

    test "returns nil when no match exists in the index" do
      mtga = TestFactory.build_mtga_card(expansion_code: "FUTURE", collector_number: "999")
      assert Pairing.for_mtga(mtga, %{}) == nil
    end

    test "returns nil for MTGA card with empty expansion_code" do
      mtga = TestFactory.build_mtga_card(expansion_code: "", collector_number: "001")
      scryfall = TestFactory.build_scryfall_card(set_code: "FOO", collector_number: "001")
      index = %{{"FOO", "001"} => scryfall}

      assert Pairing.for_mtga(mtga, index) == nil
    end

    test "returns nil for MTGA card with empty collector_number" do
      mtga = TestFactory.build_mtga_card(expansion_code: "SOS", collector_number: "")
      scryfall = TestFactory.build_scryfall_card(set_code: "SOS", collector_number: "001")
      index = %{{"SOS", "001"} => scryfall}

      assert Pairing.for_mtga(mtga, index) == nil
    end

    test "returns nil for MTGA card with nil expansion_code" do
      mtga = TestFactory.build_mtga_card(expansion_code: nil, collector_number: "001")
      assert Pairing.for_mtga(mtga, %{{"SOS", "001"} => :unused}) == nil
    end

    test "defensive case normalisation: matches when MTGA emits lowercase set code" do
      mtga = TestFactory.build_mtga_card(expansion_code: "sos", collector_number: "001")
      scryfall = TestFactory.build_scryfall_card(set_code: "SOS", collector_number: "001")

      # Index is built with upcase keys (per the orchestrator's
      # build_scryfall_by_set_number); Pairing upper-cases the MTGA code
      # so the lookup hits.
      index = %{{"SOS", "001"} => scryfall}

      assert Pairing.for_mtga(mtga, index) == scryfall
    end

    test "doesn't blow up when index is empty" do
      mtga = TestFactory.build_mtga_card(expansion_code: "SOS", collector_number: "001")
      assert Pairing.for_mtga(mtga, %{}) == nil
    end
  end
end
