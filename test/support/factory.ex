defmodule Scry2.TestFactory do
  @moduledoc """
  Factory helpers for tests.

  Two flavours, following the media-centaur / Scry2 convention:

    * `build_*/1` — plain structs with sensible defaults, no DB. Use for
      pure-function tests (async: true).
    * `create_*/1` — persists via the owning context, returns the loaded
      record. Use for resource tests (`use Scry2.DataCase`).

  Attrs can be either a keyword list or a map.
  """

  alias Scry2.Cards
  alias Scry2.Cards.{Card, MtgaCard, ScryfallCard, Set}
  alias Scry2.Decks
  alias Scry2.Drafts
  alias Scry2.Drafts.{Draft, Pick}
  alias Scry2.Events
  alias Scry2.Events.Deck.{DeckSelected, DeckSubmitted, DeckUpdated}

  alias Scry2.Events.Draft.{
    DraftCompleted,
    DraftPickMade,
    DraftStarted,
    HumanDraftPackOffered,
    HumanDraftPickMade
  }

  alias Scry2.Events.Deck.DeckInventory

  alias Scry2.Events.Economy.{
    CardsAcquired,
    CardsRemoved,
    CollectionUpdated,
    InventorySnapshot,
    InventoryUpdated
  }

  alias Scry2.Events.Event.{
    EventCourseUpdated,
    EventJoined,
    EventRecordChanged,
    EventRewardClaimed,
    PairingEntered
  }

  alias Scry2.Events.Gameplay.{
    GameConceded,
    MulliganDecided,
    MulliganOffered,
    StartingPlayerChosen
  }

  alias Scry2.Events.Match.{DieRolled, GameCompleted, MatchCompleted, MatchCreated}

  alias Scry2.Events.Progression.{
    DailyWinEarned,
    DailyWinsStatus,
    MasteryMilestoneReached,
    MasteryProgress,
    QuestAssigned,
    QuestCompleted,
    QuestProgressed,
    QuestStatus,
    RankAdvanced,
    RankMatchRecorded,
    RankSnapshot,
    WeeklyWinEarned
  }

  alias Scry2.Events.Session.{SessionDisconnected, SessionStarted}
  alias Scry2.Matches
  alias Scry2.Matches.{DeckSubmission, Game, Match}
  alias Scry2.MtgaLogIngestion
  alias Scry2.MtgaLogIngestion.{Cursor, EventRecord}
  alias Scry2.Players
  alias Scry2.Players.Player

  # ── build_* (no DB) ─────────────────────────────────────────────────────

  def build_player(attrs \\ %{}) do
    defaults = %{
      mtga_user_id: "TESTUSER" <> random_suffix(),
      screen_name: "Test Player",
      first_seen_at: DateTime.utc_now(:second)
    }

    struct(Player, Map.merge(defaults, Map.new(attrs)))
  end

  def build_set(attrs \\ %{}) do
    defaults = %{code: "TST", name: "Test Set", released_at: ~D[2026-01-01]}
    struct(Set, Map.merge(defaults, Map.new(attrs)))
  end

  def build_card(attrs \\ %{}) do
    defaults = %{
      # arena_id stays nil by default — tests that care about it set it
      # explicitly. It's nullable in the schema (backfilled from Scryfall
      # after the lands17 import) and the unique index is partial
      # (WHERE arena_id IS NOT NULL), so multiple nil rows don't collide.
      arena_id: nil,
      lands17_id: 12_345,
      name: "Test Card",
      rarity: "common",
      color_identity: "W",
      mana_value: 1,
      types: "Creature",
      is_booster: true,
      raw: %{}
    }

    struct(Card, Map.merge(defaults, Map.new(attrs)))
  end

  def build_match(attrs \\ %{}) do
    defaults = %{
      mtga_match_id: "test-match-" <> random_suffix(),
      event_name: "PremierDraft_LCI_20260401",
      format: "premier_draft",
      started_at: DateTime.utc_now(:second),
      num_games: 2,
      won: true
    }

    struct(Match, Map.merge(defaults, Map.new(attrs)))
  end

  def build_game(attrs \\ %{}) do
    defaults = %{
      game_number: 1,
      on_play: true,
      num_mulligans: 0,
      num_turns: 9,
      won: true,
      main_colors: "WU"
    }

    struct(Game, Map.merge(defaults, Map.new(attrs)))
  end

  def build_deck_submission(attrs \\ %{}) do
    defaults = %{
      mtga_deck_id: "test-deck-" <> random_suffix(),
      name: "Test Deck",
      main_deck: %{"cards" => [%{"arena_id" => 91_234, "count" => 4}]},
      sideboard: %{"cards" => []},
      submitted_at: DateTime.utc_now(:second)
    }

    struct(DeckSubmission, Map.merge(defaults, Map.new(attrs)))
  end

  def build_draft(attrs \\ %{}) do
    defaults = %{
      mtga_draft_id: "test-draft-" <> random_suffix(),
      event_name: "PremierDraft_LCI_20260401",
      format: "premier",
      set_code: "LCI",
      started_at: DateTime.utc_now(:second)
    }

    struct(Draft, Map.merge(defaults, Map.new(attrs)))
  end

  def build_pick(attrs \\ %{}) do
    defaults = %{
      pack_number: 1,
      pick_number: 1,
      picked_arena_id: 91_234,
      pack_arena_ids: %{"cards" => [91_234, 91_235]},
      pool_arena_ids: %{"cards" => []},
      picked_at: DateTime.utc_now(:second)
    }

    struct(Pick, Map.merge(defaults, Map.new(attrs)))
  end

  def build_mastery_progress(attrs \\ %{}) do
    defaults = %{
      node_states: %{
        "PlayFamiliar1" => %{"Status" => "Completed"},
        "PlayFamiliar2" => %{"Status" => "Completed"},
        "Reset" => %{"Status" => "Available"}
      },
      milestone_states: %{"TutorialComplete" => true},
      total_nodes: 3,
      completed_nodes: 2,
      occurred_at: DateTime.utc_now(:second)
    }

    struct(MasteryProgress, Map.merge(defaults, Map.new(attrs)))
  end

  def build_mtga_card(attrs \\ %{}) do
    defaults = %{
      arena_id: :rand.uniform(1_000_000),
      name: "Test MTGA Card",
      expansion_code: "TST",
      collector_number: "1",
      rarity: 2,
      colors: "",
      types: "2",
      is_token: false,
      is_digital_only: false,
      art_id: 12_345,
      power: "",
      toughness: "",
      mana_value: 0
    }

    struct(MtgaCard, Map.merge(defaults, Map.new(attrs)))
  end

  def build_scryfall_card(attrs \\ %{}) do
    defaults = %{
      scryfall_id: "scryfallid-" <> random_suffix(),
      oracle_id: "oracleid-" <> random_suffix(),
      arena_id: nil,
      name: "Test Scryfall Card",
      set_code: "tst",
      collector_number: "1",
      type_line: "Creature — Test",
      oracle_text: "Test oracle text.",
      mana_cost: "{1}{W}",
      cmc: 2.0,
      colors: "W",
      color_identity: "W",
      rarity: "common",
      layout: "normal",
      image_uris: %{"normal" => "https://example.com/card.jpg"}
    }

    struct(ScryfallCard, Map.merge(defaults, Map.new(attrs)))
  end

  def build_event_record(attrs \\ %{}) do
    defaults = %{
      event_type: "MatchStart",
      mtga_timestamp: DateTime.utc_now(:second),
      file_offset: System.unique_integer([:positive]),
      source_file: "/tmp/fixture-player.log",
      raw_json: ~s({"event":"MatchStart"}),
      processed: false,
      inserted_at: DateTime.utc_now(:second)
    }

    struct(EventRecord, Map.merge(defaults, Map.new(attrs)))
  end

  # ── build_* domain events (no DB) ───────────────────────────────────────
  #
  # These return typed domain event structs as projectors receive them
  # (after rehydrate_with_metadata injects :id and stamps :player_id).
  # The :id field is NOT part of the struct — it's added by Events.append!
  # during persistence and injected via Map.put on rehydration.

  def build_match_created(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      mtga_match_id: "test-match-" <> random_suffix(),
      event_name: "PremierDraft_LCI_20260401",
      opponent_screen_name: "TestOpponent",
      opponent_user_id: nil,
      platform: nil,
      opponent_platform: nil,
      opponent_rank_class: nil,
      opponent_rank_tier: nil,
      opponent_leaderboard_percentile: nil,
      opponent_leaderboard_placement: nil,
      occurred_at: DateTime.utc_now(:second),
      player_rank: "Gold 1",
      format: "premier_draft",
      format_type: "limited"
    }

    struct(MatchCreated, Map.merge(defaults, Map.new(attrs)))
  end

  def build_match_completed(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      mtga_match_id: "test-match-" <> random_suffix(),
      occurred_at: DateTime.utc_now(:second),
      won: true,
      num_games: 2,
      reason: nil,
      game_results: nil
    }

    struct(MatchCompleted, Map.merge(defaults, Map.new(attrs)))
  end

  def build_game_completed(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      mtga_match_id: "test-match-" <> random_suffix(),
      game_number: 1,
      on_play: true,
      won: true,
      num_mulligans: 0,
      opponent_num_mulligans: 0,
      num_turns: 9,
      self_life_total: 20,
      opponent_life_total: 0,
      win_reason: nil,
      super_format: nil,
      occurred_at: DateTime.utc_now(:second)
    }

    struct(GameCompleted, Map.merge(defaults, Map.new(attrs)))
  end

  def build_deck_submitted(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      mtga_match_id: "test-match-" <> random_suffix(),
      mtga_deck_id: "test-deck-" <> random_suffix(),
      main_deck: [%{"arena_id" => 91_234, "count" => 4}],
      sideboard: [],
      occurred_at: DateTime.utc_now(:second),
      deck_colors: "WU"
    }

    struct(DeckSubmitted, Map.merge(defaults, Map.new(attrs)))
  end

  def build_deck_updated(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      deck_id: "test-deck-" <> random_suffix(),
      deck_name: "Test Deck",
      format: "Standard",
      action_type: "Updated",
      main_deck: [%{arena_id: 91_234, count: 4}, %{arena_id: 91_235, count: 2}],
      sideboard: [%{arena_id: 91_300, count: 1}],
      occurred_at: DateTime.utc_now(:second),
      main_deck_added: [],
      main_deck_removed: [],
      sideboard_added: [],
      sideboard_removed: []
    }

    struct(DeckUpdated, Map.merge(defaults, Map.new(attrs)))
  end

  def build_mulligan_offered(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      mtga_match_id: "test-match-" <> random_suffix(),
      seat_id: 1,
      hand_size: 7,
      hand_arena_ids: [91_234, 91_235, 91_236, 91_237, 91_238, 91_239, 91_240],
      occurred_at: DateTime.utc_now(:second),
      land_count: 3,
      nonland_count: 4,
      total_cmc: 12.0,
      cmc_distribution: %{"1" => 2, "2" => 1, "3" => 1},
      color_distribution: %{"W" => 3, "U" => 1},
      card_names: %{"91234" => "Plains", "91235" => "Island"}
    }

    struct(MulliganOffered, Map.merge(defaults, Map.new(attrs)))
  end

  def build_draft_started(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      mtga_draft_id: "test-draft-" <> random_suffix(),
      event_name: "QuickDraft_LCI_20260401",
      set_code: "LCI",
      occurred_at: DateTime.utc_now(:second)
    }

    struct(DraftStarted, Map.merge(defaults, Map.new(attrs)))
  end

  def build_draft_pick_made(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      mtga_draft_id: "test-draft-" <> random_suffix(),
      pack_number: 1,
      pick_number: 1,
      picked_arena_id: 91_234,
      pack_arena_ids: [91_234, 91_235, 91_236],
      auto_pick: false,
      time_remaining: nil,
      occurred_at: DateTime.utc_now(:second)
    }

    struct(DraftPickMade, Map.merge(defaults, Map.new(attrs)))
  end

  def build_human_draft_pack_offered(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      mtga_draft_id: "test-draft-" <> random_suffix(),
      pack_number: 1,
      pick_number: 2,
      pack_arena_ids: [91_234, 91_235, 91_236, 91_237, 91_238],
      occurred_at: DateTime.utc_now(:second)
    }

    struct(HumanDraftPackOffered, Map.merge(defaults, Map.new(attrs)))
  end

  def build_human_draft_pick_made(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      mtga_draft_id: "test-draft-" <> random_suffix(),
      pack_number: 1,
      pick_number: 1,
      picked_arena_ids: [91_234],
      occurred_at: DateTime.utc_now(:second)
    }

    struct(HumanDraftPickMade, Map.merge(defaults, Map.new(attrs)))
  end

  def build_draft_completed(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      mtga_draft_id: "test-draft-" <> random_suffix(),
      event_name: "PremierDraft_FDN_20260401",
      is_bot_draft: false,
      card_pool_arena_ids: [91_234, 91_235, 91_236],
      occurred_at: DateTime.utc_now(:second)
    }

    struct(DraftCompleted, Map.merge(defaults, Map.new(attrs)))
  end

  def build_session_started(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      client_id: "TESTUSER" <> random_suffix(),
      screen_name: "Test Player",
      session_id: "sess-" <> random_suffix(),
      occurred_at: DateTime.utc_now(:second)
    }

    struct(SessionStarted, Map.merge(defaults, Map.new(attrs)))
  end

  def build_session_disconnected(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      occurred_at: DateTime.utc_now(:second)
    }

    struct(SessionDisconnected, Map.merge(defaults, Map.new(attrs)))
  end

  def build_die_rolled(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      mtga_match_id: "test-match-" <> random_suffix(),
      self_roll: 18,
      opponent_roll: 5,
      self_goes_first: true,
      occurred_at: DateTime.utc_now(:second)
    }

    struct(DieRolled, Map.merge(defaults, Map.new(attrs)))
  end

  def build_starting_player_chosen(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      mtga_match_id: "test-match-" <> random_suffix(),
      chose_play: true,
      occurred_at: DateTime.utc_now(:second)
    }

    struct(StartingPlayerChosen, Map.merge(defaults, Map.new(attrs)))
  end

  def build_mulligan_decided(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      mtga_match_id: "test-match-" <> random_suffix(),
      decision: "keep",
      occurred_at: DateTime.utc_now(:second)
    }

    struct(MulliganDecided, Map.merge(defaults, Map.new(attrs)))
  end

  def build_game_conceded(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      mtga_match_id: "test-match-" <> random_suffix(),
      scope: nil,
      occurred_at: DateTime.utc_now(:second)
    }

    struct(GameConceded, Map.merge(defaults, Map.new(attrs)))
  end

  def build_pairing_entered(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      event_name: "PremierDraft_FDN_20260401",
      occurred_at: DateTime.utc_now(:second)
    }

    struct(PairingEntered, Map.merge(defaults, Map.new(attrs)))
  end

  def build_event_joined(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      event_name: "PremierDraft_FDN_20260401",
      course_id: nil,
      entry_currency_type: nil,
      entry_fee: nil,
      occurred_at: DateTime.utc_now(:second)
    }

    struct(EventJoined, Map.merge(defaults, Map.new(attrs)))
  end

  def build_event_reward_claimed(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      event_name: "PremierDraft_FDN_20260401",
      final_wins: nil,
      final_losses: nil,
      gems_awarded: nil,
      gold_awarded: nil,
      boosters_awarded: nil,
      card_pool: nil,
      occurred_at: DateTime.utc_now(:second)
    }

    struct(EventRewardClaimed, Map.merge(defaults, Map.new(attrs)))
  end

  def build_deck_selected(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      event_name: "QuickDraft_FDN",
      deck_name: "Test Deck",
      main_deck: [],
      sideboard: [],
      occurred_at: DateTime.utc_now(:second)
    }

    struct(DeckSelected, Map.merge(defaults, Map.new(attrs)))
  end

  def build_rank_snapshot(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      constructed_class: "Gold",
      constructed_level: 2,
      constructed_step: 3,
      constructed_matches_won: 15,
      constructed_matches_lost: 10,
      constructed_percentile: nil,
      constructed_leaderboard_placement: nil,
      limited_class: "Silver",
      limited_level: 1,
      limited_step: 0,
      limited_matches_won: 5,
      limited_matches_lost: 3,
      limited_percentile: nil,
      limited_leaderboard_placement: nil,
      season_ordinal: 88,
      occurred_at: DateTime.utc_now(:second)
    }

    struct(RankSnapshot, Map.merge(defaults, Map.new(attrs)))
  end

  def build_inventory_updated(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      gold: 5000,
      gems: 1200,
      wildcards_common: 25,
      wildcards_uncommon: 18,
      wildcards_rare: 6,
      wildcards_mythic: 3,
      vault_progress: 42.5,
      draft_tokens: 0,
      sealed_tokens: 0,
      occurred_at: DateTime.utc_now(:second)
    }

    struct(InventoryUpdated, Map.merge(defaults, Map.new(attrs)))
  end

  def build_collection_updated(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      card_counts: %{91_234 => 4, 91_235 => 2, 91_236 => 1},
      occurred_at: DateTime.utc_now(:second)
    }

    struct(CollectionUpdated, Map.merge(defaults, Map.new(attrs)))
  end

  def build_inventory_snapshot(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      gold: 5000,
      gems: 1200,
      vault_progress: 42.5,
      wildcards_common: 25,
      wildcards_uncommon: 18,
      wildcards_rare: 6,
      wildcards_mythic: 3,
      draft_tokens: 0,
      sealed_tokens: 0,
      boosters: [%{set_code: "FDN", count: 3}],
      occurred_at: DateTime.utc_now(:second)
    }

    struct(InventorySnapshot, Map.merge(defaults, Map.new(attrs)))
  end

  def build_quest_status(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      quests: [
        %{
          quest_id: "daily_win_1",
          goal: 5,
          progress: 2,
          quest_track: "Daily",
          reward_gold: 250,
          reward_xp: nil
        }
      ],
      occurred_at: DateTime.utc_now(:second)
    }

    struct(QuestStatus, Map.merge(defaults, Map.new(attrs)))
  end

  def build_daily_wins_status(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      daily_position: 3,
      daily_reset_at: DateTime.utc_now(:second),
      weekly_position: 10,
      weekly_reset_at: DateTime.utc_now(:second),
      occurred_at: DateTime.utc_now(:second)
    }

    struct(DailyWinsStatus, Map.merge(defaults, Map.new(attrs)))
  end

  def build_deck_inventory(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      decks: [
        %{deck_id: "deck-abc-123", name: "My Deck", format: "Standard"},
        %{deck_id: "deck-def-456", name: "Draft Deck", format: "Limited"}
      ],
      occurred_at: DateTime.utc_now(:second)
    }

    struct(DeckInventory, Map.merge(defaults, Map.new(attrs)))
  end

  def build_event_course_updated(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      event_name: "QuickDraft_FDN_20260323",
      current_wins: 2,
      current_losses: 1,
      current_module: "Draft",
      card_pool: [91_234, 91_235],
      occurred_at: DateTime.utc_now(:second)
    }

    struct(EventCourseUpdated, Map.merge(defaults, Map.new(attrs)))
  end

  def build_rank_advanced(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      constructed_class: "Gold",
      constructed_level: 2,
      constructed_step: 3,
      constructed_matches_won: 15,
      constructed_matches_lost: 10,
      constructed_percentile: nil,
      constructed_leaderboard_placement: nil,
      limited_class: "Silver",
      limited_level: 1,
      limited_step: 0,
      limited_matches_won: 5,
      limited_matches_lost: 3,
      limited_percentile: nil,
      limited_leaderboard_placement: nil,
      season_ordinal: 88,
      occurred_at: DateTime.utc_now(:second)
    }

    struct(RankAdvanced, Map.merge(defaults, Map.new(attrs)))
  end

  def build_rank_match_recorded(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      format: :constructed,
      won: true,
      wins: 16,
      losses: 10,
      occurred_at: DateTime.utc_now(:second)
    }

    struct(RankMatchRecorded, Map.merge(defaults, Map.new(attrs)))
  end

  def build_daily_win_earned(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      new_position: 4,
      occurred_at: DateTime.utc_now(:second)
    }

    struct(DailyWinEarned, Map.merge(defaults, Map.new(attrs)))
  end

  def build_weekly_win_earned(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      new_position: 11,
      occurred_at: DateTime.utc_now(:second)
    }

    struct(WeeklyWinEarned, Map.merge(defaults, Map.new(attrs)))
  end

  def build_mastery_milestone_reached(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      milestone_key: "TutorialComplete",
      occurred_at: DateTime.utc_now(:second)
    }

    struct(MasteryMilestoneReached, Map.merge(defaults, Map.new(attrs)))
  end

  def build_quest_progressed(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      quest_id: "daily_win_1",
      new_progress: 3,
      goal: 5,
      occurred_at: DateTime.utc_now(:second)
    }

    struct(QuestProgressed, Map.merge(defaults, Map.new(attrs)))
  end

  def build_quest_completed(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      quest_id: "daily_win_1",
      occurred_at: DateTime.utc_now(:second)
    }

    struct(QuestCompleted, Map.merge(defaults, Map.new(attrs)))
  end

  def build_quest_assigned(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      quest_id: "daily_win_2",
      goal: 5,
      quest_track: "Daily",
      occurred_at: DateTime.utc_now(:second)
    }

    struct(QuestAssigned, Map.merge(defaults, Map.new(attrs)))
  end

  def build_cards_acquired(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      cards: %{91_234 => 2, 91_235 => 1},
      occurred_at: DateTime.utc_now(:second)
    }

    struct(CardsAcquired, Map.merge(defaults, Map.new(attrs)))
  end

  def build_cards_removed(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      cards: %{91_236 => 1},
      occurred_at: DateTime.utc_now(:second)
    }

    struct(CardsRemoved, Map.merge(defaults, Map.new(attrs)))
  end

  def build_event_record_changed(attrs \\ %{}) do
    defaults = %{
      player_id: nil,
      event_name: "QuickDraft_FDN_20260323",
      wins: 2,
      losses: 1,
      current_module: "Draft",
      card_pool: [91_234, 91_235],
      occurred_at: DateTime.utc_now(:second)
    }

    struct(EventRecordChanged, Map.merge(defaults, Map.new(attrs)))
  end

  # ── create_* domain events (persisted to event store) ──────────────────

  @doc """
  Persists a domain event struct to the `domain_events` table via
  `Events.append!/3`. Returns the persisted `%Events.EventRecord{}`.

  Pass `:source_record` and `:sequence` in opts if needed.
  """
  def create_domain_event(domain_event, opts \\ []) do
    source_record = Keyword.get(opts, :source_record)
    Events.append!(domain_event, source_record, opts)
  end

  # ── create_* (persisted) ────────────────────────────────────────────────

  def create_player(attrs \\ %{}) do
    attrs = Map.new(attrs)
    mtga_user_id = attrs[:mtga_user_id] || "TESTUSER" <> random_suffix()
    screen_name = attrs[:screen_name] || "Test Player"
    Players.find_or_create!(mtga_user_id, screen_name)
  end

  def create_set(attrs \\ %{}) do
    attrs |> build_set() |> Map.from_struct() |> Cards.upsert_set!()
  end

  def create_card(attrs \\ %{}) do
    attrs = Map.new(attrs)
    # Make lands17_id unique per call to avoid test cross-contamination.
    attrs = Map.put_new(attrs, :lands17_id, :rand.uniform(1_000_000_000))
    attrs |> build_card() |> Map.from_struct() |> Map.drop([:__meta__]) |> Cards.upsert_card!()
  end

  def create_match(attrs \\ %{}) do
    attrs
    |> build_match()
    |> Map.from_struct()
    |> Map.drop([:__meta__, :games, :deck_submissions])
    |> Matches.upsert_match!()
  end

  def create_game(attrs \\ %{}) do
    match = attrs[:match] || attrs["match"] || create_match(%{})
    base = attrs |> Map.new() |> Map.drop([:match])

    build_game(base)
    |> Map.from_struct()
    |> Map.drop([:__meta__, :match])
    |> Map.put(:match_id, match.id)
    |> Matches.upsert_game!()
  end

  def create_deck(attrs \\ %{}) do
    base = Map.new(attrs)
    mtga_deck_id = base[:mtga_deck_id] || "deck-#{System.unique_integer([:positive])}"

    Decks.upsert_deck!(%{
      mtga_deck_id: mtga_deck_id,
      current_name: base[:current_name] || "Test Deck",
      current_main_deck: base[:current_main_deck] || %{"cards" => []},
      current_sideboard: base[:current_sideboard] || %{"cards" => []},
      format: base[:format] || "Standard",
      deck_colors: base[:deck_colors] || "WU",
      first_seen_at: base[:first_seen_at] || DateTime.utc_now(:second),
      last_played_at: base[:last_played_at] || DateTime.utc_now(:second)
    })
  end

  def create_deck_match_result(attrs \\ %{}) do
    base = Map.new(attrs)
    deck = base[:deck] || create_deck()

    Decks.upsert_match_result!(%{
      mtga_deck_id: deck.mtga_deck_id,
      mtga_match_id: base[:mtga_match_id] || "match-#{System.unique_integer([:positive])}",
      won: Map.get(base, :won, true),
      format_type: base[:format_type] || "Standard",
      on_play: Map.get(base, :on_play, true),
      player_rank: base[:player_rank],
      started_at: base[:started_at] || DateTime.utc_now(:second),
      completed_at: base[:completed_at] || DateTime.utc_now(:second)
    })
  end

  def create_draft(attrs \\ %{}) do
    attrs
    |> build_draft()
    |> Map.from_struct()
    |> Map.drop([:__meta__, :picks])
    |> Drafts.upsert_draft!()
  end

  def create_pick(attrs \\ %{}) do
    draft = attrs[:draft] || attrs["draft"] || create_draft(%{})
    base = attrs |> Map.new() |> Map.drop([:draft])

    build_pick(base)
    |> Map.from_struct()
    |> Map.drop([:__meta__, :draft])
    |> Map.put(:draft_id, draft.id)
    |> Drafts.upsert_pick!()
  end

  def create_mtga_card(attrs \\ %{}) do
    attrs
    |> build_mtga_card()
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> then(&Cards.upsert_mtga_card!/1)
  end

  def create_scryfall_card(attrs \\ %{}) do
    attrs
    |> build_scryfall_card()
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> then(&Cards.upsert_scryfall_card!/1)
  end

  def create_event_record(attrs \\ %{}) do
    record =
      attrs
      |> build_event_record()
      |> Map.from_struct()
      |> Map.drop([:__meta__])
      |> MtgaLogIngestion.insert_event!()

    record || raise "create_event_record: duplicate (source_file, file_offset)"
  end

  def create_cursor(attrs \\ %{}) do
    defaults = %{
      file_path: "/tmp/fixture-player-#{random_suffix()}.log",
      byte_offset: 0,
      last_read_at: DateTime.utc_now(:second)
    }

    attrs |> Map.new() |> then(&Map.merge(defaults, &1)) |> MtgaLogIngestion.put_cursor!()
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp random_suffix, do: Integer.to_string(:rand.uniform(1_000_000_000), 36)

  # Silence unused-alias warnings for test support code.
  @compile {:no_warn_unused,
            [
              CardsAcquired,
              CardsRemoved,
              Cursor,
              DailyWinEarned,
              DeckSelected,
              DeckSubmission,
              DieRolled,
              CollectionUpdated,
              DraftCompleted,
              EventRecord,
              EventRecordChanged,
              HumanDraftPackOffered,
              HumanDraftPickMade,
              InventorySnapshot,
              InventoryUpdated,
              MasteryMilestoneReached,
              MasteryProgress,
              MtgaCard,
              Players,
              QuestAssigned,
              QuestCompleted,
              QuestProgressed,
              RankAdvanced,
              RankMatchRecorded,
              RankSnapshot,
              ScryfallCard,
              SessionDisconnected,
              SessionStarted,
              StartingPlayerChosen,
              WeeklyWinEarned
            ]}
end
