defmodule Scry2.DecksTest do
  use Scry2.DataCase

  alias Scry2.Cards
  alias Scry2.Decks
  alias Scry2.Decks.{Deck, GameSubmission, MatchResult}
  alias Scry2.TestFactory
  alias Scry2.Topics

  describe "upsert_deck!/1" do
    test "inserts a new deck and broadcasts" do
      Topics.subscribe(Topics.decks_updates())

      deck =
        Decks.upsert_deck!(%{mtga_deck_id: "d-abc", current_name: "My Deck", format: "Standard"})

      assert %Deck{mtga_deck_id: "d-abc", current_name: "My Deck"} = deck
      assert_receive {:deck_updated, "d-abc"}
    end

    test "updates an existing deck by mtga_deck_id (idempotent)" do
      first = Decks.upsert_deck!(%{mtga_deck_id: "d-xyz", current_name: "Old Name"})
      second = Decks.upsert_deck!(%{mtga_deck_id: "d-xyz", current_name: "New Name"})

      assert first.id == second.id
      assert second.current_name == "New Name"
      assert Scry2.Repo.aggregate(Deck, :count) == 1
    end
  end

  describe "get_deck/1" do
    test "returns the deck with the given mtga_deck_id" do
      deck = TestFactory.create_deck(%{mtga_deck_id: "d-lookup"})
      assert Decks.get_deck("d-lookup").id == deck.id
    end

    test "returns nil when deck does not exist" do
      assert Decks.get_deck("d-missing") == nil
    end
  end

  describe "upsert_match_result!/1" do
    test "inserts a new match result and broadcasts" do
      Topics.subscribe(Topics.decks_updates())

      deck = TestFactory.create_deck()

      result =
        Decks.upsert_match_result!(%{
          mtga_deck_id: deck.mtga_deck_id,
          mtga_match_id: "m-001",
          won: true,
          format_type: "Standard"
        })

      assert %MatchResult{won: true} = result
      assert_receive {:deck_updated, _}
    end

    test "updates existing result by (mtga_deck_id, mtga_match_id) (idempotent)" do
      deck = TestFactory.create_deck()
      attrs = %{mtga_deck_id: deck.mtga_deck_id, mtga_match_id: "m-idem"}

      first = Decks.upsert_match_result!(Map.put(attrs, :won, nil))
      second = Decks.upsert_match_result!(Map.put(attrs, :won, true))

      assert first.id == second.id
      assert second.won == true
      assert Scry2.Repo.aggregate(MatchResult, :count) == 1
    end
  end

  describe "upsert_game_submission!/1" do
    test "inserts a game submission (idempotent by deck/match/game)" do
      deck = TestFactory.create_deck()

      attrs = %{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: "m-gs-001",
        game_number: 1,
        main_deck: %{"cards" => []},
        sideboard: %{"cards" => []}
      }

      first = Decks.upsert_game_submission!(attrs)
      second = Decks.upsert_game_submission!(Map.put(attrs, :game_number, 1))

      assert first.id == second.id
      assert Scry2.Repo.aggregate(GameSubmission, :count) == 1
    end

    test "stores separate submissions for different game numbers" do
      deck = TestFactory.create_deck()
      base = %{mtga_deck_id: deck.mtga_deck_id, mtga_match_id: "m-multi"}

      Decks.upsert_game_submission!(Map.put(base, :game_number, 1))
      Decks.upsert_game_submission!(Map.put(base, :game_number, 2))

      assert Scry2.Repo.aggregate(GameSubmission, :count) == 2
    end
  end

  describe "list_decks_with_stats/0" do
    test "returns only decks with at least one completed match" do
      deck_with_match = TestFactory.create_deck(%{mtga_deck_id: "d-played"})
      _deck_no_match = TestFactory.create_deck(%{mtga_deck_id: "d-unplayed"})

      TestFactory.create_deck_match_result(%{deck: deck_with_match, won: true})

      result = Decks.list_decks_with_stats()
      deck_ids = Enum.map(result, & &1.deck.mtga_deck_id)

      assert "d-played" in deck_ids
      refute "d-unplayed" in deck_ids
    end

    test "aggregates BO1 and BO3 stats separately" do
      deck = TestFactory.create_deck()

      TestFactory.create_deck_match_result(%{deck: deck, format_type: "Standard", won: true})
      TestFactory.create_deck_match_result(%{deck: deck, format_type: "Standard", won: false})
      TestFactory.create_deck_match_result(%{deck: deck, format_type: "Traditional", won: true})

      [entry] = Decks.list_decks_with_stats()

      assert entry.bo1.total == 2
      assert entry.bo1.wins == 1
      assert entry.bo1.win_rate == 50.0
      assert entry.bo3.total == 1
      assert entry.bo3.wins == 1
      assert entry.bo3.win_rate == 100.0
    end
  end

  describe "get_deck_performance/1" do
    test "returns zero stats for a deck with no completed matches" do
      deck = TestFactory.create_deck()
      perf = Decks.get_deck_performance(deck.mtga_deck_id)

      assert perf.bo1.total == 0
      assert perf.bo3.total == 0
      assert perf.cumulative_win_rate == %{bo1: [], bo3: []}
    end

    test "separates BO1 and BO3 results" do
      deck = TestFactory.create_deck()
      TestFactory.create_deck_match_result(%{deck: deck, format_type: "Standard", won: true})
      TestFactory.create_deck_match_result(%{deck: deck, format_type: "Traditional", won: false})

      perf = Decks.get_deck_performance(deck.mtga_deck_id)

      assert perf.bo1.total == 1
      assert perf.bo1.wins == 1
      assert perf.bo3.total == 1
      assert perf.bo3.losses == 1
    end
  end

  describe "get_deck_sideboard_diff/1" do
    test "returns diffs only for matches with multiple game submissions" do
      deck = TestFactory.create_deck()

      # Two games — should produce a diff
      Decks.upsert_game_submission!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: "m-bo3",
        game_number: 1,
        main_deck: %{"cards" => []},
        sideboard: %{"cards" => [%{"arena_id" => 100, "count" => 2}]}
      })

      Decks.upsert_game_submission!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: "m-bo3",
        game_number: 2,
        main_deck: %{"cards" => []},
        sideboard: %{"cards" => [%{"arena_id" => 200, "count" => 1}]}
      })

      # Single game — should be excluded
      Decks.upsert_game_submission!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: "m-bo1",
        game_number: 1,
        main_deck: %{"cards" => []},
        sideboard: %{"cards" => []}
      })

      diffs = Decks.get_deck_sideboard_diff(deck.mtga_deck_id)

      assert length(diffs) == 1
      [diff] = diffs
      assert diff.mtga_match_id == "m-bo3"
      assert Enum.any?(diff.changes.added, &(&1.arena_id == 200))
      assert Enum.any?(diff.changes.removed, &(&1.arena_id == 100))
    end
  end

  describe "list_matches_for_deck/2" do
    test "returns all completed matches and total count with no opts" do
      deck = TestFactory.create_deck()
      TestFactory.create_deck_match_result(%{deck: deck, won: true})
      TestFactory.create_deck_match_result(%{deck: deck, won: false})

      {matches, total} = Decks.list_matches_for_deck(deck.mtga_deck_id)

      assert total == 2
      assert length(matches) == 2
    end

    test "paginates with limit and offset" do
      deck = TestFactory.create_deck()

      for i <- 1..3 do
        Decks.upsert_match_result!(%{
          mtga_deck_id: deck.mtga_deck_id,
          mtga_match_id: "m-pag-#{i}",
          won: true,
          format_type: "Standard",
          started_at: DateTime.add(DateTime.utc_now(:second), -i, :second)
        })
      end

      {page1, total} = Decks.list_matches_for_deck(deck.mtga_deck_id, limit: 2, offset: 0)
      assert total == 3
      assert length(page1) == 2

      {page2, _} = Decks.list_matches_for_deck(deck.mtga_deck_id, limit: 2, offset: 2)
      assert length(page2) == 1
    end

    test "filters to BO3 matches only with format: :bo3" do
      deck = TestFactory.create_deck()

      TestFactory.create_deck_match_result(%{deck: deck, format_type: "Traditional", won: true})
      TestFactory.create_deck_match_result(%{deck: deck, format_type: "Standard", won: true})

      {bo3_matches, bo3_total} = Decks.list_matches_for_deck(deck.mtga_deck_id, format: :bo3)

      assert bo3_total == 1
      assert length(bo3_matches) == 1
      assert hd(bo3_matches).format_type == "Traditional"
    end

    test "filters to BO1 matches only with format: :bo1" do
      deck = TestFactory.create_deck()

      TestFactory.create_deck_match_result(%{deck: deck, format_type: "Standard", won: true})
      TestFactory.create_deck_match_result(%{deck: deck, format_type: "Traditional", won: true})

      {bo1_matches, bo1_total} = Decks.list_matches_for_deck(deck.mtga_deck_id, format: :bo1)

      assert bo1_total == 1
      assert length(bo1_matches) == 1
      assert hd(bo1_matches).format_type == "Standard"
    end

    test "excludes incomplete matches (won is nil)" do
      deck = TestFactory.create_deck()

      TestFactory.create_deck_match_result(%{deck: deck, won: true})

      Decks.upsert_match_result!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: "m-incomplete",
        won: nil
      })

      {matches, total} = Decks.list_matches_for_deck(deck.mtga_deck_id)

      assert total == 1
      assert length(matches) == 1
    end

    test "returns results newest first" do
      deck = TestFactory.create_deck()
      now = DateTime.utc_now(:second)

      Decks.upsert_match_result!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: "m-older",
        won: true,
        started_at: DateTime.add(now, -100, :second)
      })

      Decks.upsert_match_result!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: "m-newer",
        won: true,
        started_at: now
      })

      {matches, _} = Decks.list_matches_for_deck(deck.mtga_deck_id)

      assert hd(matches).mtga_match_id == "m-newer"
    end
  end

  describe "latest_format/1" do
    test "returns :bo3 when no matches exist" do
      deck = TestFactory.create_deck()

      assert Decks.latest_format(deck.mtga_deck_id) == :bo3
    end

    test "returns :bo3 when most recent match is Traditional" do
      deck = TestFactory.create_deck()
      now = DateTime.utc_now(:second)

      Decks.upsert_match_result!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: "m-standard",
        won: true,
        format_type: "Standard",
        started_at: DateTime.add(now, -100, :second)
      })

      Decks.upsert_match_result!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: "m-trad",
        won: true,
        format_type: "Traditional",
        started_at: now
      })

      assert Decks.latest_format(deck.mtga_deck_id) == :bo3
    end

    test "returns :bo1 when most recent match is Standard" do
      deck = TestFactory.create_deck()
      now = DateTime.utc_now(:second)

      Decks.upsert_match_result!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: "m-trad",
        won: true,
        format_type: "Traditional",
        started_at: DateTime.add(now, -100, :second)
      })

      Decks.upsert_match_result!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: "m-standard",
        won: true,
        format_type: "Standard",
        started_at: now
      })

      assert Decks.latest_format(deck.mtga_deck_id) == :bo1
    end
  end

  describe "match_counts_by_format/1" do
    test "returns zero counts for a deck with no matches" do
      deck = TestFactory.create_deck()

      assert Decks.match_counts_by_format(deck.mtga_deck_id) == %{bo1: 0, bo3: 0}
    end

    test "counts BO1 and BO3 matches separately" do
      deck = TestFactory.create_deck()

      TestFactory.create_deck_match_result(%{deck: deck, format_type: "Standard", won: true})
      TestFactory.create_deck_match_result(%{deck: deck, format_type: "Standard", won: false})
      TestFactory.create_deck_match_result(%{deck: deck, format_type: "Traditional", won: true})

      assert Decks.match_counts_by_format(deck.mtga_deck_id) == %{bo1: 2, bo3: 1}
    end

    test "excludes incomplete matches from counts" do
      deck = TestFactory.create_deck()

      TestFactory.create_deck_match_result(%{deck: deck, format_type: "Standard", won: true})

      Decks.upsert_match_result!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: "m-incomplete",
        won: nil,
        format_type: "Standard"
      })

      assert Decks.match_counts_by_format(deck.mtga_deck_id) == %{bo1: 1, bo3: 0}
    end
  end

  describe "card_performance/1" do
    test "excludes opponent draws (is_self_draw: false)" do
      deck = TestFactory.create_deck()
      match_id = "m-opponent-#{System.unique_integer([:positive])}"
      opponent_arena_id = System.unique_integer([:positive])

      Decks.upsert_match_result!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: match_id,
        won: true,
        format_type: "Standard"
      })

      Cards.upsert_mtga_card!(%{arena_id: opponent_arena_id, name: "Opponent Spell", rarity: 3})

      Decks.upsert_game_draw!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: match_id,
        game_number: 1,
        card_arena_id: opponent_arena_id,
        match_won: true,
        is_self_draw: false,
        occurred_at: ~U[2026-01-01 00:00:00Z]
      })

      result_ids = deck.mtga_deck_id |> Decks.card_performance() |> Enum.map(& &1.card_arena_id)
      refute opponent_arena_id in result_ids
    end

    test "excludes token cards (is_token: true in MtgaCard)" do
      deck = TestFactory.create_deck()
      match_id = "m-token-#{System.unique_integer([:positive])}"
      token_arena_id = System.unique_integer([:positive])

      Decks.upsert_match_result!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: match_id,
        won: true,
        format_type: "Standard"
      })

      Cards.upsert_mtga_card!(%{
        arena_id: token_arena_id,
        name: "Treasure",
        is_token: true,
        rarity: 0
      })

      Decks.upsert_game_draw!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: match_id,
        game_number: 1,
        card_arena_id: token_arena_id,
        match_won: true,
        is_self_draw: true,
        occurred_at: ~U[2026-01-01 00:00:00Z]
      })

      result_ids = deck.mtga_deck_id |> Decks.card_performance() |> Enum.map(& &1.card_arena_id)
      refute token_arena_id in result_ids
    end

    test "excludes arena_ids with no card table entry (nil card_name)" do
      deck = TestFactory.create_deck()
      match_id = "m-unknown-#{System.unique_integer([:positive])}"
      unknown_arena_id = System.unique_integer([:positive])

      Decks.upsert_match_result!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: match_id,
        won: true,
        format_type: "Standard"
      })

      Decks.upsert_game_draw!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: match_id,
        game_number: 1,
        card_arena_id: unknown_arena_id,
        match_won: true,
        is_self_draw: true,
        occurred_at: ~U[2026-01-01 00:00:00Z]
      })

      result_ids = deck.mtga_deck_id |> Decks.card_performance() |> Enum.map(& &1.card_arena_id)
      refute unknown_arena_id in result_ids
    end

    test "includes self draws of known non-token cards" do
      deck = TestFactory.create_deck()
      match_id = "m-self-#{System.unique_integer([:positive])}"
      card_arena_id = System.unique_integer([:positive])

      Decks.upsert_match_result!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: match_id,
        won: true,
        format_type: "Standard"
      })

      Cards.upsert_mtga_card!(%{arena_id: card_arena_id, name: "Lightning Bolt", rarity: 2})

      Decks.upsert_game_draw!(%{
        mtga_deck_id: deck.mtga_deck_id,
        mtga_match_id: match_id,
        game_number: 1,
        card_arena_id: card_arena_id,
        match_won: true,
        is_self_draw: true,
        occurred_at: ~U[2026-01-01 00:00:00Z]
      })

      result_ids = deck.mtga_deck_id |> Decks.card_performance() |> Enum.map(& &1.card_arena_id)
      assert card_arena_id in result_ids
    end
  end

  describe "merge_match_result_observation/1" do
    alias Scry2.LiveState.Snapshot

    test "writes all gap-filler fields and broadcasts on decks:updates" do
      match_result =
        TestFactory.create_deck_match_result(%{
          deck: TestFactory.create_deck(%{mtga_deck_id: "D-100"}),
          mtga_match_id: "M-100",
          player_rank: nil
        })

      # Subscribe AFTER create_deck_match_result so we don't see the factory's own broadcast.
      Topics.subscribe(Topics.decks_updates())

      snapshot = %Snapshot{
        mtga_match_id: "M-100",
        opponent_screen_name: "RealName#12345",
        opponent_ranking_class: 5,
        opponent_ranking_tier: 2,
        opponent_mythic_percentile: nil,
        opponent_mythic_placement: nil,
        local_ranking_class: 4,
        local_ranking_tier: 4
      }

      assert {:ok, updated} = Decks.merge_match_result_observation(snapshot)
      assert updated.id == match_result.id
      assert updated.opponent_screen_name == "RealName#12345"
      assert updated.opponent_rank == "Diamond 2"
      assert updated.player_rank == "Platinum 4"

      assert_receive {:deck_updated, mtga_deck_id}, 100
      assert mtga_deck_id == "D-100"
    end

    test "preserves log-derived non-nil fields when memory only fills some" do
      result =
        TestFactory.create_deck_match_result(%{
          deck: TestFactory.create_deck(%{mtga_deck_id: "D-200"}),
          mtga_match_id: "M-200"
        })

      # Seed opponent_rank directly — the factory doesn't forward this key,
      # but the production write path (MatchProjection) does. We're
      # simulating an existing log-derived rank value here to verify it
      # survives an incoming memory observation that lacks rank data.
      {:ok, _} =
        result
        |> Ecto.Changeset.change(opponent_rank: "Bronze 1")
        |> Scry2.Repo.update()

      snapshot = %Snapshot{
        mtga_match_id: "M-200",
        opponent_screen_name: "MemoryName",
        opponent_ranking_class: nil,
        opponent_ranking_tier: nil
      }

      assert {:ok, updated} = Decks.merge_match_result_observation(snapshot)
      assert updated.opponent_screen_name == "MemoryName"
      assert updated.opponent_rank == "Bronze 1"
    end

    test "no-ops with all-nil enrichable fields" do
      TestFactory.create_deck_match_result(%{
        deck: TestFactory.create_deck(%{mtga_deck_id: "D-300"}),
        mtga_match_id: "M-300"
      })

      Topics.subscribe(Topics.decks_updates())

      snapshot = %Snapshot{mtga_match_id: "M-300", reader_version: "unknown"}
      assert :ok = Decks.merge_match_result_observation(snapshot)
      refute_receive {:deck_updated, _}, 50
    end

    test "returns :ok when match_result not found" do
      snapshot = %Snapshot{
        mtga_match_id: "M-MISSING",
        opponent_screen_name: "Someone"
      }

      assert :ok = Decks.merge_match_result_observation(snapshot)
    end

    test "writes mythic percentile and placement when present" do
      TestFactory.create_deck_match_result(%{
        deck: TestFactory.create_deck(%{mtga_deck_id: "D-400"}),
        mtga_match_id: "M-400"
      })

      snapshot = %Snapshot{
        mtga_match_id: "M-400",
        opponent_ranking_class: 6,
        opponent_ranking_tier: nil,
        opponent_mythic_percentile: 88,
        opponent_mythic_placement: 142
      }

      assert {:ok, updated} = Decks.merge_match_result_observation(snapshot)
      assert updated.opponent_rank == "Mythic"
      assert updated.opponent_rank_mythic_percentile == 88
      assert updated.opponent_rank_mythic_placement == 142
    end

    test "drops Mythic tier when walker emits the meaningless tier=1" do
      TestFactory.create_deck_match_result(%{
        deck: TestFactory.create_deck(%{mtga_deck_id: "D-MYTHIC-1"}),
        mtga_match_id: "M-MYTHIC-1"
      })

      snapshot = %Snapshot{
        mtga_match_id: "M-MYTHIC-1",
        opponent_ranking_class: 6,
        opponent_ranking_tier: 1,
        opponent_mythic_percentile: 88
      }

      assert {:ok, updated} = Decks.merge_match_result_observation(snapshot)
      assert updated.opponent_rank == "Mythic"
      refute updated.opponent_rank =~ "1"
      assert updated.opponent_rank_mythic_percentile == 88
    end
  end

  describe "stamp_draft_final_build!/4" do
    test "stamps main deck and sideboard onto a draft deck row" do
      deck =
        TestFactory.create_deck(%{
          mtga_deck_id: "draft:QuickDraft_SOS_20260430",
          current_main_deck: %{}
        })

      at = ~U[2026-04-30 12:00:00Z]

      Scry2.Decks.stamp_draft_final_build!(
        deck.mtga_deck_id,
        [%{"arena_id" => 93_811, "count" => 3}],
        [%{"arena_id" => 93_999, "count" => 1}],
        at
      )

      reloaded = Scry2.Decks.get_deck(deck.mtga_deck_id)
      assert reloaded.current_main_deck == %{"cards" => [%{"arena_id" => 93_811, "count" => 3}]}
      assert reloaded.current_sideboard == %{"cards" => [%{"arena_id" => 93_999, "count" => 1}]}
      assert reloaded.last_updated_at == at
    end

    test "latest build wins, earlier build is ignored" do
      deck =
        TestFactory.create_deck(%{
          mtga_deck_id: "draft:QuickDraft_SOS_20260430",
          current_main_deck: %{}
        })

      Scry2.Decks.stamp_draft_final_build!(
        deck.mtga_deck_id,
        [%{"arena_id" => 1, "count" => 1}],
        [],
        ~U[2026-04-30 14:00:00Z]
      )

      Scry2.Decks.stamp_draft_final_build!(
        deck.mtga_deck_id,
        [%{"arena_id" => 2, "count" => 1}],
        [],
        ~U[2026-04-30 12:00:00Z]
      )

      reloaded = Scry2.Decks.get_deck(deck.mtga_deck_id)
      assert reloaded.current_main_deck == %{"cards" => [%{"arena_id" => 1, "count" => 1}]}
    end

    test "leaves composition_hash nil so the deck stays draft-distinguishable" do
      deck =
        TestFactory.create_deck(%{
          mtga_deck_id: "draft:QuickDraft_SOS_20260430",
          current_main_deck: %{}
        })

      Scry2.Decks.stamp_draft_final_build!(
        deck.mtga_deck_id,
        [%{"arena_id" => 1, "count" => 1}],
        [],
        ~U[2026-04-30 12:00:00Z]
      )

      assert Scry2.Decks.get_deck(deck.mtga_deck_id).composition_hash == nil
    end

    test "no-op when the deck row does not exist" do
      assert :ok =
               Scry2.Decks.stamp_draft_final_build!(
                 "draft:nope",
                 [%{"arena_id" => 1, "count" => 1}],
                 [],
                 ~U[2026-04-30 12:00:00Z]
               )
    end

    test "broadcasts deck_updated after a successful stamp" do
      deck =
        TestFactory.create_deck(%{
          mtga_deck_id: "draft:QuickDraft_SOS_20260430",
          current_main_deck: %{}
        })

      Topics.subscribe(Topics.decks_updates())

      Scry2.Decks.stamp_draft_final_build!(
        deck.mtga_deck_id,
        [%{"arena_id" => 93_811, "count" => 3}],
        [],
        ~U[2026-04-30 12:00:00Z]
      )

      assert_receive {:deck_updated, "draft:QuickDraft_SOS_20260430"}
    end
  end

  describe "backfill_draft_builds!/0" do
    test "stamps the latest submission onto existing draft decks, leaves others untouched" do
      draft =
        TestFactory.create_deck(%{
          mtga_deck_id: "draft:QuickDraft_SOS_20260430",
          current_main_deck: %{}
        })

      TestFactory.create_deck(%{
        mtga_deck_id: "real-deck-1",
        current_main_deck: %{"cards" => [%{"arena_id" => 5, "count" => 4}]}
      })

      Scry2.Decks.upsert_game_submission!(%{
        mtga_deck_id: draft.mtga_deck_id,
        mtga_match_id: "m1",
        game_number: 1,
        main_deck: %{"cards" => [%{"arena_id" => 10, "count" => 2}]},
        sideboard: %{"cards" => []},
        submitted_at: ~U[2026-04-30 12:00:00Z]
      })

      Scry2.Decks.upsert_game_submission!(%{
        mtga_deck_id: draft.mtga_deck_id,
        mtga_match_id: "m2",
        game_number: 1,
        main_deck: %{"cards" => [%{"arena_id" => 11, "count" => 3}]},
        sideboard: %{"cards" => []},
        submitted_at: ~U[2026-04-30 13:00:00Z]
      })

      assert Scry2.Decks.backfill_draft_builds!() == 1

      assert Scry2.Decks.get_deck("draft:QuickDraft_SOS_20260430").current_main_deck ==
               %{"cards" => [%{"arena_id" => 11, "count" => 3}]}

      assert Scry2.Decks.get_deck("real-deck-1").current_main_deck ==
               %{"cards" => [%{"arena_id" => 5, "count" => 4}]}
    end

    test "is idempotent" do
      draft =
        TestFactory.create_deck(%{
          mtga_deck_id: "draft:QuickDraft_SOS_20260430",
          current_main_deck: %{}
        })

      Scry2.Decks.upsert_game_submission!(%{
        mtga_deck_id: draft.mtga_deck_id,
        mtga_match_id: "m1",
        game_number: 1,
        main_deck: %{"cards" => [%{"arena_id" => 10, "count" => 2}]},
        sideboard: %{"cards" => []},
        submitted_at: ~U[2026-04-30 12:00:00Z]
      })

      Scry2.Decks.backfill_draft_builds!()
      first = Scry2.Decks.get_deck(draft.mtga_deck_id).current_main_deck
      Scry2.Decks.backfill_draft_builds!()
      assert Scry2.Decks.get_deck(draft.mtga_deck_id).current_main_deck == first
    end
  end

  describe "update_deck_flags!/2" do
    test "updates starred and archived and broadcasts" do
      Topics.subscribe(Topics.decks_updates())
      deck = TestFactory.create_deck(%{mtga_deck_id: "d-flags"})

      updated = Decks.update_deck_flags!(deck, %{starred: true, archived: true})

      assert %Deck{starred: true, archived: true, mtga_deck_id: "d-flags"} = updated
      assert_receive {:deck_updated, "d-flags"}
    end

    test "leaves other fields untouched" do
      deck = TestFactory.create_deck(%{mtga_deck_id: "d-flags-2", current_name: "Keep Me"})

      updated = Decks.update_deck_flags!(deck, %{starred: true})

      assert updated.current_name == "Keep Me"
      assert updated.starred == true
      assert updated.archived == false
    end
  end

  describe "toggle_starred!/1" do
    test "flips the starred flag" do
      deck = TestFactory.create_deck(%{mtga_deck_id: "d-star"})
      assert deck.starred == false

      starred = Decks.toggle_starred!(deck.mtga_deck_id)
      assert starred.starred == true

      unstarred = Decks.toggle_starred!(deck.mtga_deck_id)
      assert unstarred.starred == false
    end

    test "returns nil when the deck does not exist" do
      assert Decks.toggle_starred!("missing-deck") == nil
    end
  end

  describe "toggle_archived!/1" do
    test "flips the archived flag" do
      deck = TestFactory.create_deck(%{mtga_deck_id: "d-arch"})
      assert deck.archived == false

      archived = Decks.toggle_archived!(deck.mtga_deck_id)
      assert archived.archived == true

      unarchived = Decks.toggle_archived!(deck.mtga_deck_id)
      assert unarchived.archived == false
    end

    test "returns nil when the deck does not exist" do
      assert Decks.toggle_archived!("missing-deck") == nil
    end
  end

  describe "list_decks_with_stats/2 — status and starred_only filters" do
    test "status: :active excludes archived decks" do
      active = TestFactory.create_deck(%{mtga_deck_id: "d-active"})
      archived = TestFactory.create_deck(%{mtga_deck_id: "d-archived"})
      TestFactory.create_deck_match_result(%{deck: active, won: true})
      TestFactory.create_deck_match_result(%{deck: archived, won: true})
      Decks.update_deck_flags!(archived, %{archived: true})

      result = Decks.list_decks_with_stats(nil, status: :active)
      deck_ids = Enum.map(result, & &1.deck.mtga_deck_id)

      assert "d-active" in deck_ids
      refute "d-archived" in deck_ids
    end

    test "status: :archived returns only archived decks" do
      active = TestFactory.create_deck(%{mtga_deck_id: "d-active-2"})
      archived = TestFactory.create_deck(%{mtga_deck_id: "d-archived-2"})
      TestFactory.create_deck_match_result(%{deck: active, won: true})
      TestFactory.create_deck_match_result(%{deck: archived, won: true})
      Decks.update_deck_flags!(archived, %{archived: true})

      result = Decks.list_decks_with_stats(nil, status: :archived)
      deck_ids = Enum.map(result, & &1.deck.mtga_deck_id)

      refute "d-active-2" in deck_ids
      assert "d-archived-2" in deck_ids
    end

    test "status: :all returns both active and archived" do
      active = TestFactory.create_deck(%{mtga_deck_id: "d-active-3"})
      archived = TestFactory.create_deck(%{mtga_deck_id: "d-archived-3"})
      TestFactory.create_deck_match_result(%{deck: active, won: true})
      TestFactory.create_deck_match_result(%{deck: archived, won: true})
      Decks.update_deck_flags!(archived, %{archived: true})

      result = Decks.list_decks_with_stats(nil, status: :all)
      deck_ids = Enum.map(result, & &1.deck.mtga_deck_id)

      assert "d-active-3" in deck_ids
      assert "d-archived-3" in deck_ids
    end

    test "starred_only: true returns only starred decks" do
      starred = TestFactory.create_deck(%{mtga_deck_id: "d-star-1"})
      plain = TestFactory.create_deck(%{mtga_deck_id: "d-plain-1"})
      TestFactory.create_deck_match_result(%{deck: starred, won: true})
      TestFactory.create_deck_match_result(%{deck: plain, won: true})
      Decks.update_deck_flags!(starred, %{starred: true})

      result = Decks.list_decks_with_stats(nil, starred_only: true)
      deck_ids = Enum.map(result, & &1.deck.mtga_deck_id)

      assert "d-star-1" in deck_ids
      refute "d-plain-1" in deck_ids
    end
  end

  describe "group_member_ids/1 (decklist grouping)" do
    setup do
      TestFactory.create_card(arena_id: 105_175, name: "Island")
      TestFactory.create_card(arena_id: 102_727, name: "Island")
      TestFactory.create_card(arena_id: 95_072, name: "Mountain")
      :ok
    end

    defp deck_of(id, arena_id, count) do
      TestFactory.create_deck(%{
        mtga_deck_id: id,
        current_main_deck: %{"cards" => [%{"arena_id" => arena_id, "count" => count}]}
      })
    end

    test "groups constructed decks that share a decklist across printings" do
      deck_of("a", 105_175, 60)
      deck_of("b", 102_727, 60)
      deck_of("c", 95_072, 60)

      assert Enum.sort(Decks.group_member_ids("a")) == ["a", "b"]
      assert Enum.sort(Decks.group_member_ids("b")) == ["a", "b"]
      assert Decks.group_member_ids("c") == ["c"]
    end

    test "a below-threshold (limited-size) deck is its own group" do
      deck_of("small1", 105_175, 40)
      deck_of("small2", 102_727, 40)

      assert Decks.group_member_ids("small1") == ["small1"]
    end

    test "a draft deck is never grouped" do
      TestFactory.create_deck(%{
        mtga_deck_id: "draft:QuickDraft_SOS",
        current_main_deck: %{"cards" => [%{"arena_id" => 105_175, "count" => 60}]}
      })

      deck_of("constructed", 102_727, 60)

      assert Decks.group_member_ids("draft:QuickDraft_SOS") == ["draft:QuickDraft_SOS"]
    end

    test "an unknown id returns itself" do
      assert Decks.group_member_ids("nope") == ["nope"]
    end
  end

  describe "deck-detail reads aggregate across a decklist group" do
    # Two decks that are the SAME 60-card list under different Island printings
    # (arena_ids 105175 and 102727, both "Island") group together at the ≥55
    # threshold. Every per-deck detail read must aggregate across both ids no
    # matter which member id it is queried by.
    setup do
      TestFactory.create_card(arena_id: 105_175, name: "Island")
      TestFactory.create_card(arena_id: 102_727, name: "Island")

      grouped_list = %{"cards" => [%{"arena_id" => 105_175, "count" => 60}]}
      grouped_list_b = %{"cards" => [%{"arena_id" => 102_727, "count" => 60}]}

      TestFactory.create_deck(%{
        mtga_deck_id: "grp-a",
        current_main_deck: grouped_list,
        last_played_at: ~U[2026-01-05 00:00:00Z]
      })

      TestFactory.create_deck(%{
        mtga_deck_id: "grp-b",
        current_main_deck: grouped_list_b,
        last_played_at: ~U[2026-01-06 00:00:00Z]
      })

      # Confidence check: the two decks really do group.
      assert Enum.sort(Decks.group_member_ids("grp-a")) == ["grp-a", "grp-b"]

      # Match results: 2 BO1 on member A (1W/1L), 1 BO1 win on member B → group total 3.
      TestFactory.create_deck_match_result(%{
        deck: %{mtga_deck_id: "grp-a"},
        mtga_match_id: "mr-a1",
        format_type: "Standard",
        won: true,
        started_at: ~U[2026-01-01 00:00:00Z]
      })

      TestFactory.create_deck_match_result(%{
        deck: %{mtga_deck_id: "grp-a"},
        mtga_match_id: "mr-a2",
        format_type: "Standard",
        won: false,
        started_at: ~U[2026-01-02 00:00:00Z]
      })

      TestFactory.create_deck_match_result(%{
        deck: %{mtga_deck_id: "grp-b"},
        mtga_match_id: "mr-b1",
        format_type: "Standard",
        won: true,
        started_at: ~U[2026-01-03 00:00:00Z]
      })

      # Mulligan hands (kept, Island in opener) on both members → card 105175
      # sample count of 2 across the group.
      Decks.upsert_mulligan_hand!(%{
        mtga_deck_id: "grp-a",
        mtga_match_id: "mull-a",
        seat_id: 1,
        hand_size: 7,
        hand_arena_ids: %{"cards" => [105_175]},
        decision: "kept",
        match_won: true,
        occurred_at: ~U[2026-01-01 00:00:00Z]
      })

      Decks.upsert_mulligan_hand!(%{
        mtga_deck_id: "grp-b",
        mtga_match_id: "mull-b",
        seat_id: 1,
        hand_size: 7,
        hand_arena_ids: %{"cards" => [105_175]},
        decision: "kept",
        match_won: true,
        occurred_at: ~U[2026-01-02 00:00:00Z]
      })

      # Cards drawn (self draws) on both members for the same Island.
      Decks.upsert_game_draw!(%{
        mtga_deck_id: "grp-a",
        mtga_match_id: "draw-a",
        game_number: 1,
        card_arena_id: 105_175,
        match_won: true,
        is_self_draw: true,
        occurred_at: ~U[2026-01-01 00:00:00Z]
      })

      Decks.upsert_game_draw!(%{
        mtga_deck_id: "grp-b",
        mtga_match_id: "draw-b",
        game_number: 1,
        card_arena_id: 105_175,
        match_won: true,
        is_self_draw: true,
        occurred_at: ~U[2026-01-02 00:00:00Z]
      })

      # One deck version per member (version_number collides across ids).
      Decks.upsert_deck_version!(%{
        mtga_deck_id: "grp-a",
        version_number: 1,
        main_deck: grouped_list,
        sideboard: %{"cards" => []},
        occurred_at: ~U[2026-01-01 00:00:00Z]
      })

      Decks.upsert_deck_version!(%{
        mtga_deck_id: "grp-b",
        version_number: 1,
        main_deck: grouped_list_b,
        sideboard: %{"cards" => []},
        occurred_at: ~U[2026-01-02 00:00:00Z]
      })

      :ok
    end

    for member_id <- ["grp-a", "grp-b"] do
      test "list_matches_for_deck aggregates the group via #{member_id}" do
        {matches, total} = Decks.list_matches_for_deck(unquote(member_id))
        assert total == 3
        assert length(matches) == 3
      end

      test "match_counts_by_format aggregates the group via #{member_id}" do
        assert Decks.match_counts_by_format(unquote(member_id)) == %{bo1: 3, bo3: 0}
      end

      test "get_deck_performance bo1 total aggregates the group via #{member_id}" do
        perf = Decks.get_deck_performance(unquote(member_id))
        assert perf.bo1.total == 3
        assert perf.bo1.wins == 2
        assert perf.bo1.losses == 1
      end

      test "card_performance reflects both ids' samples via #{member_id}" do
        island =
          Enum.find(Decks.card_performance(unquote(member_id)), &(&1.card_arena_id == 105_175))

        assert island
        # Opening hands from both members (mull-a, mull-b).
        assert island.oh_games == 2
        # Self-draws from both members (draw-a, draw-b).
        assert island.gd_games == 2
        # GIH = openers + draws across all four distinct matches in the group.
        assert island.gih_games == 4
      end

      test "mulligan_analytics counts hands across the group via #{member_id}" do
        assert Decks.mulligan_analytics(unquote(member_id)).total_hands == 2
      end

      test "count_versions counts versions across the group via #{member_id}" do
        assert Decks.count_versions(unquote(member_id)) == 2
      end

      test "get_deck_versions returns all member versions via #{member_id}" do
        assert length(Decks.get_deck_versions(unquote(member_id))) == 2
      end
    end
  end

  describe "list_decks_with_stats/2 — decklist grouping" do
    # grp-a and grp-b are the same 60-card list under Island printings
    # 105175/102727, so they collapse into ONE summary. solo is a distinct
    # decklist and stays on its own.
    setup do
      TestFactory.create_card(arena_id: 105_175, name: "Island")
      TestFactory.create_card(arena_id: 102_727, name: "Island")
      TestFactory.create_card(arena_id: 95_072, name: "Mountain")

      TestFactory.create_deck(%{
        mtga_deck_id: "grp-a",
        current_main_deck: %{"cards" => [%{"arena_id" => 105_175, "count" => 60}]},
        last_played_at: ~U[2026-01-05 00:00:00Z]
      })

      TestFactory.create_deck(%{
        mtga_deck_id: "grp-b",
        current_main_deck: %{"cards" => [%{"arena_id" => 102_727, "count" => 60}]},
        last_played_at: ~U[2026-01-06 00:00:00Z]
      })

      TestFactory.create_deck(%{
        mtga_deck_id: "solo",
        current_main_deck: %{"cards" => [%{"arena_id" => 95_072, "count" => 60}]},
        last_played_at: ~U[2026-01-04 00:00:00Z]
      })

      :ok
    end

    test "collapses a group into one summary with summed stats and the most-recently-played canonical" do
      # grp-a: 1W/1L BO1 · grp-b: 1W BO1 + 1W BO3 · solo: 1W BO1
      TestFactory.create_deck_match_result(%{
        deck: %{mtga_deck_id: "grp-a"},
        format_type: "Standard",
        won: true
      })

      TestFactory.create_deck_match_result(%{
        deck: %{mtga_deck_id: "grp-a"},
        format_type: "Standard",
        won: false
      })

      TestFactory.create_deck_match_result(%{
        deck: %{mtga_deck_id: "grp-b"},
        format_type: "Standard",
        won: true
      })

      TestFactory.create_deck_match_result(%{
        deck: %{mtga_deck_id: "grp-b"},
        format_type: "Traditional",
        won: true
      })

      TestFactory.create_deck_match_result(%{
        deck: %{mtga_deck_id: "solo"},
        format_type: "Standard",
        won: true
      })

      summaries = Decks.list_decks_with_stats()
      ids = Enum.map(summaries, & &1.deck.mtga_deck_id)

      # One entry stands in for the group, and it is the most-recently-played member.
      assert length(summaries) == 2
      assert "grp-b" in ids
      refute "grp-a" in ids
      assert "solo" in ids

      group = Enum.find(summaries, &(&1.deck.mtga_deck_id == "grp-b"))
      assert group.bo1.total == 3
      assert group.bo1.wins == 2
      assert group.bo1.losses == 1
      assert group.bo3.total == 1
      assert group.bo3.wins == 1
    end

    test "unplayed groups are excluded by default, included with only_played: false" do
      TestFactory.create_deck_match_result(%{deck: %{mtga_deck_id: "solo"}, won: true})

      default_ids = Enum.map(Decks.list_decks_with_stats(), & &1.deck.mtga_deck_id)
      refute "grp-a" in default_ids
      refute "grp-b" in default_ids
      assert "solo" in default_ids

      all_ids =
        Enum.map(Decks.list_decks_with_stats(nil, only_played: false), & &1.deck.mtga_deck_id)

      assert "grp-b" in all_ids
      refute "grp-a" in all_ids
    end

    test "starred_only matches a group when ANY member is starred" do
      TestFactory.create_deck_match_result(%{deck: %{mtga_deck_id: "grp-a"}, won: true})

      # Star only the NON-canonical member.
      Decks.toggle_starred!("grp-a")

      [entry] = Decks.list_decks_with_stats(nil, starred_only: true)
      assert entry.deck.mtga_deck_id == "grp-b"
      assert entry.deck.starred == true
    end

    test "status uses group-level archived (ALL members) semantics" do
      TestFactory.create_deck_match_result(%{deck: %{mtga_deck_id: "grp-a"}, won: true})

      # Archive only ONE member → group is NOT archived yet.
      Decks.toggle_archived!("grp-a")

      active_ids =
        Enum.map(Decks.list_decks_with_stats(nil, status: :active), & &1.deck.mtga_deck_id)

      assert "grp-b" in active_ids

      archived_ids =
        Enum.map(Decks.list_decks_with_stats(nil, status: :archived), & &1.deck.mtga_deck_id)

      refute "grp-b" in archived_ids

      # Archive the other member too → whole group counts as archived.
      Decks.toggle_archived!("grp-b")

      archived_after =
        Enum.map(Decks.list_decks_with_stats(nil, status: :archived), & &1.deck.mtga_deck_id)

      assert "grp-b" in archived_after

      active_after =
        Enum.map(Decks.list_decks_with_stats(nil, status: :active), & &1.deck.mtga_deck_id)

      refute "grp-b" in active_after
    end
  end

  describe "canonical_deck/1" do
    setup do
      TestFactory.create_card(arena_id: 105_175, name: "Island")
      TestFactory.create_card(arena_id: 102_727, name: "Island")
      :ok
    end

    test "resolves any split-off id to the most-recently-played member" do
      main = %{"cards" => [%{"arena_id" => 105_175, "count" => 60}]}
      main2 = %{"cards" => [%{"arena_id" => 102_727, "count" => 60}]}

      TestFactory.create_deck(%{
        mtga_deck_id: "old",
        current_name: "Week 3 MSH",
        current_main_deck: main,
        last_played_at: ~U[2026-07-14 00:00:00Z]
      })

      TestFactory.create_deck(%{
        mtga_deck_id: "new",
        current_name: "Dragonstorm",
        current_main_deck: main2,
        last_played_at: ~U[2026-07-18 00:00:00Z]
      })

      assert Decks.canonical_deck("old").mtga_deck_id == "new"
      assert Decks.canonical_deck("new").mtga_deck_id == "new"
      assert Decks.canonical_deck("new").current_name == "Dragonstorm"
    end

    test "returns nil for an unknown id" do
      assert Decks.canonical_deck("nope") == nil
    end
  end
end
