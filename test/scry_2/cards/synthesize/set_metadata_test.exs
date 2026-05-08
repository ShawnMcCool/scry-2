defmodule Scry2.Cards.Synthesize.SetMetadataTest do
  @moduledoc """
  Tests for `Scry2.Cards.Synthesize.SetMetadata` — pure per-set metadata
  extraction. The load-bearing case is reading set name + released_at
  from Scryfall rows that have `arena_id = nil` (the SOS / TMT / TLA
  bug ADR-038 fixes).
  """

  use ExUnit.Case, async: true

  alias Scry2.Cards.Synthesize.SetMetadata
  alias Scry2.TestFactory

  describe "extract/1" do
    test "regression: pulls name + released_at from Scryfall rows with arena_id=nil" do
      # Mirror of the SOS situation: 0 cards in this set have arena_id
      # populated, but Scryfall has the proper set_name + released_at.
      rows =
        for n <- 1..3 do
          TestFactory.build_scryfall_card(
            scryfall_id: "sos-#{n}",
            arena_id: nil,
            set_code: "SOS",
            set_name: "Secrets of Strixhaven",
            released_at: ~D[2026-04-24],
            collector_number: Integer.to_string(n)
          )
        end

      meta = SetMetadata.extract(rows)

      assert meta["SOS"].name == "Secrets of Strixhaven"
      assert meta["SOS"].released_at == ~D[2026-04-24]
    end

    test "uppercases the key regardless of input casing" do
      rows = [
        TestFactory.build_scryfall_card(
          scryfall_id: "x",
          set_code: "stx",
          set_name: "Strixhaven: School of Mages",
          released_at: ~D[2021-04-23]
        )
      ]

      meta = SetMetadata.extract(rows)
      assert Map.has_key?(meta, "STX")
      refute Map.has_key?(meta, "stx")
    end

    test "earliest released_at wins across cards in the same set" do
      rows = [
        TestFactory.build_scryfall_card(
          scryfall_id: "j25-late",
          set_code: "j25",
          set_name: "Foundations Jumpstart",
          released_at: ~D[2024-12-15]
        ),
        TestFactory.build_scryfall_card(
          scryfall_id: "j25-mid",
          set_code: "j25",
          set_name: "Foundations Jumpstart",
          released_at: ~D[2024-11-20]
        ),
        TestFactory.build_scryfall_card(
          scryfall_id: "j25-early",
          set_code: "j25",
          set_name: "Foundations Jumpstart",
          released_at: ~D[2024-11-01]
        )
      ]

      meta = SetMetadata.extract(rows)
      assert meta["J25"].released_at == ~D[2024-11-01]
    end

    test "ignores rows with nil set_code" do
      rows = [
        TestFactory.build_scryfall_card(scryfall_id: "no-set", set_code: nil, set_name: "X")
      ]

      assert SetMetadata.extract(rows) == %{}
    end

    test "ignores rows with empty set_code" do
      rows = [
        TestFactory.build_scryfall_card(scryfall_id: "blank-set", set_code: "", set_name: "X")
      ]

      assert SetMetadata.extract(rows) == %{}
    end

    test "name from the first non-nil source wins (later nils don't overwrite)" do
      rows = [
        TestFactory.build_scryfall_card(scryfall_id: "a", set_code: "ABC", set_name: "Real Name"),
        TestFactory.build_scryfall_card(scryfall_id: "b", set_code: "ABC", set_name: nil)
      ]

      meta = SetMetadata.extract(rows)
      assert meta["ABC"].name == "Real Name"
    end

    test "released_at survives intermixed nils" do
      rows = [
        TestFactory.build_scryfall_card(
          scryfall_id: "a",
          set_code: "XYZ",
          released_at: nil
        ),
        TestFactory.build_scryfall_card(
          scryfall_id: "b",
          set_code: "XYZ",
          released_at: ~D[2024-09-27]
        ),
        TestFactory.build_scryfall_card(
          scryfall_id: "c",
          set_code: "XYZ",
          released_at: nil
        )
      ]

      meta = SetMetadata.extract(rows)
      assert meta["XYZ"].released_at == ~D[2024-09-27]
    end

    test "returns empty map for empty input" do
      assert SetMetadata.extract([]) == %{}
    end
  end
end
