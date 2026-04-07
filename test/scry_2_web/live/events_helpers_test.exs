defmodule Scry2Web.EventsHelpersTest do
  use ExUnit.Case, async: true

  alias Scry2Web.EventsHelpers

  alias Scry2.Events.{
    DeckSubmitted,
    DieRollCompleted,
    DraftPickMade,
    DraftStarted,
    EventJoined,
    GameCompleted,
    InventoryChanged,
    MatchCompleted,
    MatchCreated,
    MulliganOffered,
    PrizeClaimed,
    RankSnapshot,
    SessionStarted
  }

  describe "event_category/1" do
    test "match lifecycle events" do
      assert EventsHelpers.event_category(%MatchCreated{mtga_match_id: "m", occurred_at: now()}) ==
               :match

      assert EventsHelpers.event_category(%GameCompleted{
               mtga_match_id: "m",
               game_number: 1,
               occurred_at: now()
             }) == :match
    end

    test "draft events" do
      assert EventsHelpers.event_category(%DraftStarted{
               mtga_draft_id: "d",
               event_name: "E",
               occurred_at: now()
             }) == :draft
    end

    test "economy events" do
      assert EventsHelpers.event_category(%EventJoined{
               event_name: "E",
               occurred_at: now()
             }) == :economy
    end

    test "session events" do
      assert EventsHelpers.event_category(%SessionStarted{
               client_id: "c",
               session_id: "s",
               occurred_at: now()
             }) == :session
    end

    test "snapshot events" do
      assert EventsHelpers.event_category(%RankSnapshot{occurred_at: now()}) == :snapshot
    end
  end

  describe "type_badge_color/1" do
    test "returns daisyUI badge class for each category" do
      assert EventsHelpers.type_badge_color(:match) == "badge-success"
      assert EventsHelpers.type_badge_color(:draft) == "badge-info"
      assert EventsHelpers.type_badge_color(:economy) == "badge-warning"
      assert EventsHelpers.type_badge_color(:session) == "badge-accent"
      assert EventsHelpers.type_badge_color(:snapshot) == "badge-ghost"
    end
  end

  describe "event_summary/1" do
    test "match_created" do
      event = %MatchCreated{
        mtga_match_id: "m",
        event_name: "PremierDraft",
        opponent_screen_name: "Bob",
        occurred_at: now()
      }

      assert EventsHelpers.event_summary(event) == "vs. Bob — PremierDraft"
    end

    test "match_completed won" do
      event = %MatchCompleted{mtga_match_id: "m", won: true, num_games: 3, occurred_at: now()}
      assert EventsHelpers.event_summary(event) == "Won (3 games)"
    end

    test "match_completed lost" do
      event = %MatchCompleted{mtga_match_id: "m", won: false, num_games: 2, occurred_at: now()}
      assert EventsHelpers.event_summary(event) == "Lost (2 games)"
    end

    test "game_completed" do
      event = %GameCompleted{
        mtga_match_id: "m",
        game_number: 2,
        won: true,
        on_play: false,
        occurred_at: now()
      }

      assert EventsHelpers.event_summary(event) == "Game 2 — Won, on draw"
    end

    test "deck_submitted" do
      event = %DeckSubmitted{
        mtga_match_id: "m",
        main_deck: [1, 2, 3],
        sideboard: [4],
        occurred_at: now()
      }

      assert EventsHelpers.event_summary(event) == "3 cards main, 1 sideboard"
    end

    test "die_roll_completed" do
      event = %DieRollCompleted{
        mtga_match_id: "m",
        self_roll: 19,
        opponent_roll: 4,
        self_goes_first: true,
        occurred_at: now()
      }

      assert EventsHelpers.event_summary(event) == "Roll 19 vs 4, going first"
    end

    test "mulligan_offered" do
      event = %MulliganOffered{
        mtga_match_id: "m",
        seat_id: 1,
        hand_size: 6,
        occurred_at: now()
      }

      assert EventsHelpers.event_summary(event) == "Hand size: 6"
    end

    test "draft_started" do
      event = %DraftStarted{
        mtga_draft_id: "d",
        event_name: "PremierDraft",
        set_code: "FDN",
        occurred_at: now()
      }

      assert EventsHelpers.event_summary(event) == "PremierDraft — FDN"
    end

    test "draft_pick_made" do
      event = %DraftPickMade{
        mtga_draft_id: "d",
        pack_number: 1,
        pick_number: 3,
        picked_arena_id: 12345,
        pack_arena_ids: [],
        occurred_at: now()
      }

      assert EventsHelpers.event_summary(event) == "Pack 1, Pick 3"
    end

    test "event_joined with fee" do
      event = %EventJoined{
        event_name: "PremierDraft",
        entry_fee: 1500,
        entry_currency_type: "Gems",
        occurred_at: now()
      }

      assert EventsHelpers.event_summary(event) == "PremierDraft (1500 Gems)"
    end

    test "prize_claimed" do
      event = %PrizeClaimed{
        event_name: "PremierDraft",
        wins: 5,
        losses: 3,
        occurred_at: now()
      }

      assert EventsHelpers.event_summary(event) == "PremierDraft — 5W 3L"
    end

    test "inventory_changed with deltas" do
      event = %InventoryChanged{
        source: "EventJoin",
        gold_delta: -500,
        gems_delta: 0,
        occurred_at: now()
      }

      assert EventsHelpers.event_summary(event) == "EventJoin: -500 gold"
    end

    test "session_started" do
      event = %SessionStarted{
        client_id: "c",
        screen_name: "MyPlayer",
        session_id: "s",
        occurred_at: now()
      }

      assert EventsHelpers.event_summary(event) == "MyPlayer"
    end

    test "rank_snapshot" do
      event = %RankSnapshot{
        limited_class: "Gold",
        limited_level: 2,
        occurred_at: now()
      }

      assert EventsHelpers.event_summary(event) == "Gold 2 (Limited)"
    end
  end

  describe "correlation_label/1" do
    test "returns match label for match events" do
      event = %MatchCreated{
        mtga_match_id: "abcdefghijklmnop",
        occurred_at: now()
      }

      assert EventsHelpers.correlation_label(event) == "match:abcdefgh…"
    end

    test "returns draft label for draft events" do
      event = %DraftStarted{
        mtga_draft_id: "1234567890",
        event_name: "E",
        occurred_at: now()
      }

      assert EventsHelpers.correlation_label(event) == "draft:12345678…"
    end

    test "returns nil for events without correlation" do
      event = %RankSnapshot{occurred_at: now()}
      assert EventsHelpers.correlation_label(event) == nil
    end

    test "short IDs are not truncated" do
      event = %MatchCreated{mtga_match_id: "short", occurred_at: now()}
      assert EventsHelpers.correlation_label(event) == "match:short"
    end
  end

  defp now, do: DateTime.utc_now(:second)
end
