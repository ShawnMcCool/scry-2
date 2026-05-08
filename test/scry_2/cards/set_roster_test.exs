defmodule Scry2.Cards.SetRosterTest do
  use Scry2.DataCase, async: false

  alias Scry2.Cards
  alias Scry2.Cards.SetRoster
  alias Scry2.TestFactory

  describe "compute/0" do
    test "groups cards by set and rarity, counting unique arena_ids" do
      lci =
        TestFactory.create_set(%{code: "LCI", name: "Lost Caverns", released_at: ~D[2024-11-01]})

      mid = TestFactory.create_set(%{code: "MID", name: "Mid", released_at: ~D[2025-04-01]})

      _ =
        TestFactory.create_card(%{
          arena_id: 91_001,
          set_id: lci.id,
          rarity: "common",
          is_booster: true
        })

      _ =
        TestFactory.create_card(%{
          arena_id: 91_002,
          set_id: lci.id,
          rarity: "common",
          is_booster: true
        })

      _ =
        TestFactory.create_card(%{
          arena_id: 91_003,
          set_id: lci.id,
          rarity: "rare",
          is_booster: true
        })

      _ =
        TestFactory.create_card(%{
          arena_id: 91_010,
          set_id: mid.id,
          rarity: "mythic",
          is_booster: true
        })

      rosters = SetRoster.compute()

      assert %SetRoster{set: %Cards.Set{code: "LCI"}, totals: lci_totals} = rosters[lci.id]
      assert lci_totals == %{"common" => 2, "rare" => 1}

      assert %SetRoster{set: %Cards.Set{code: "MID"}, totals: mid_totals} = rosters[mid.id]
      assert mid_totals == %{"mythic" => 1}
    end

    test "excludes non-booster cards (Alchemy duplicates, basics, tokens)" do
      set = TestFactory.create_set(%{code: "ALC", name: "Alchemy"})

      _ =
        TestFactory.create_card(%{
          arena_id: 92_001,
          set_id: set.id,
          rarity: "rare",
          is_booster: true
        })

      _ =
        TestFactory.create_card(%{
          arena_id: 92_002,
          set_id: set.id,
          rarity: "rare",
          is_booster: false
        })

      rosters = SetRoster.compute()

      assert rosters[set.id].totals == %{"rare" => 1}
    end

    test "regression: includes non-booster cards when the set has zero booster signal (Scryfall lag)" do
      # Mirrors the SOS / TMT case as of 2026-05-08: Scryfall's bulk data
      # has the cards but `booster=false` for every row in the set.
      # Without the lag fallback, the roster would be empty.
      sos = TestFactory.create_set(%{code: "SOS", name: "Secrets of Strixhaven"})

      _ =
        TestFactory.create_card(%{
          arena_id: 99_001,
          set_id: sos.id,
          rarity: "common",
          is_booster: false
        })

      _ =
        TestFactory.create_card(%{
          arena_id: 99_002,
          set_id: sos.id,
          rarity: "uncommon",
          is_booster: false
        })

      _ =
        TestFactory.create_card(%{
          arena_id: 99_003,
          set_id: sos.id,
          rarity: "rare",
          is_booster: false
        })

      _ =
        TestFactory.create_card(%{
          arena_id: 99_004,
          set_id: sos.id,
          rarity: "mythic",
          is_booster: false
        })

      rosters = SetRoster.compute()

      assert rosters[sos.id].totals == %{
               "common" => 1,
               "uncommon" => 1,
               "rare" => 1,
               "mythic" => 1
             }
    end

    test "excludes tokens and basics regardless of booster signal" do
      # Even when a set has no booster-tagged cards (lag fallback active),
      # tokens and basics stay out of the completion roster.
      newset = TestFactory.create_set(%{code: "NEW", name: "Brand New"})

      _ =
        TestFactory.create_card(%{
          arena_id: 99_101,
          set_id: newset.id,
          rarity: "common",
          is_booster: false
        })

      _ =
        TestFactory.create_card(%{
          arena_id: 99_102,
          set_id: newset.id,
          rarity: "token",
          is_booster: false
        })

      _ =
        TestFactory.create_card(%{
          arena_id: 99_103,
          set_id: newset.id,
          rarity: "basic",
          is_booster: false
        })

      assert SetRoster.compute()[newset.id].totals == %{"common" => 1}
    end

    test "lag fallback is per-set: a set with any booster signal still uses the strict filter" do
      # Sanity: confirm the fallback doesn't leak into well-tagged sets.
      lag = TestFactory.create_set(%{code: "LAG", name: "Lagged"})
      ok = TestFactory.create_set(%{code: "OK", name: "Tagged"})

      _ =
        TestFactory.create_card(%{
          arena_id: 99_201,
          set_id: lag.id,
          rarity: "rare",
          is_booster: false
        })

      _ =
        TestFactory.create_card(%{
          arena_id: 99_202,
          set_id: ok.id,
          rarity: "rare",
          is_booster: true
        })

      _ =
        TestFactory.create_card(%{
          arena_id: 99_203,
          set_id: ok.id,
          rarity: "rare",
          is_booster: false
        })

      rosters = SetRoster.compute()

      # Lagged set: fallback engages → both implicit + explicit rares counted (one row, count=1).
      assert rosters[lag.id].totals == %{"rare" => 1}
      # Tagged set: strict filter → only the booster=true row.
      assert rosters[ok.id].totals == %{"rare" => 1}
    end

    test "ignores cards without a set_id" do
      _ =
        TestFactory.create_card(%{
          arena_id: 93_001,
          set_id: nil,
          rarity: "rare",
          is_booster: true
        })

      assert SetRoster.compute() == %{}
    end

    test "returns an empty map when no sets exist" do
      assert SetRoster.compute() == %{}
    end
  end

  describe "for/1 and label/1" do
    setup do
      set = TestFactory.create_set(%{code: "FDN", name: "Foundations"})

      _ =
        TestFactory.create_card(%{
          arena_id: 94_001,
          set_id: set.id,
          rarity: "common",
          is_booster: true
        })

      SetRoster.refresh()
      %{set: set}
    end

    test "for/1 returns a roster for a known set", %{set: set} do
      roster = SetRoster.for(set.id)
      assert roster.set.code == "FDN"
      assert roster.totals == %{"common" => 1}
    end

    test "for/1 returns nil for unknown set ids" do
      assert SetRoster.for(-1) == nil
    end

    test "label/1 returns set metadata without re-querying", %{set: set} do
      assert SetRoster.label(set.id).code == "FDN"
      assert SetRoster.label(-1) == nil
    end
  end

  describe "all/0 cache" do
    test "refresh/0 rebuilds the cache from the current DB state" do
      set = TestFactory.create_set(%{code: "FRESH", name: "Fresh"})

      _ =
        TestFactory.create_card(%{
          arena_id: 95_001,
          set_id: set.id,
          rarity: "rare",
          is_booster: true
        })

      SetRoster.refresh()

      assert SetRoster.all()[set.id].totals == %{"rare" => 1}
    end
  end

  describe "refresher" do
    alias Scry2.Cards.SetRosterRefresher
    alias Scry2.Topics

    test "rebuilds the cache when cards_refreshed fires" do
      {:ok, _pid} = start_supervised({SetRosterRefresher, name: :refresher_test})

      set = TestFactory.create_set(%{code: "RFR", name: "Refresh"})

      _ =
        TestFactory.create_card(%{
          arena_id: 96_001,
          set_id: set.id,
          rarity: "mythic",
          is_booster: true
        })

      Topics.broadcast(Topics.cards_updates(), {:cards_refreshed, 1})

      # Drain the refresher's mailbox synchronously so we can assert on the
      # post-broadcast cache state without sleeping.
      _ = :sys.get_state(:refresher_test)

      assert SetRoster.all()[set.id].totals == %{"mythic" => 1}
    end

    test "ignores unrelated messages on the topic" do
      {:ok, _pid} = start_supervised({SetRosterRefresher, name: :refresher_ignore_test})

      Topics.broadcast(Topics.cards_updates(), {:scryfall_imported, 12})

      _ = :sys.get_state(:refresher_ignore_test)

      # No assertion on cache state — message just shouldn't crash the process.
      assert Process.alive?(Process.whereis(:refresher_ignore_test))
    end
  end
end
