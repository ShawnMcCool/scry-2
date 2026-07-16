defmodule Scry2.Decks.DeckProjectionTest do
  use Scry2.DataCase

  import Scry2.TestFactory
  import Scry2.ProjectorCase

  alias Scry2.Decks.{DeckProjection, MatchResult}
  alias Scry2.Repo

  alias Scry2.Decks.Deck

  describe "deck format inference from event_name" do
    test "backfills nil format from match event_name on DeckSubmitted" do
      player = create_player()
      deck_id = "test-deck-#{System.unique_integer([:positive])}"
      match_id = "test-match-#{System.unique_integer([:positive])}"

      events = [
        # DeckUpdated with nil format (simulates filtered event-type format)
        build_deck_updated(%{
          player_id: player.id,
          deck_id: deck_id,
          deck_name: "Test Deck",
          format: nil,
          main_deck: [%{arena_id: 91_234, count: 4}],
          sideboard: []
        }),
        build_match_created(%{
          player_id: player.id,
          mtga_match_id: match_id,
          event_name: "Ladder",
          format: "ranked",
          format_type: "Constructed"
        }),
        build_deck_submitted(%{
          player_id: player.id,
          mtga_match_id: match_id,
          mtga_deck_id: deck_id,
          main_deck: [%{"arena_id" => 91_234, "count" => 4}]
        })
      ]

      project_events(DeckProjection, events)

      deck = Repo.get_by(Deck, mtga_deck_id: deck_id)
      assert deck.format == "Standard"
    end

    test "does not overwrite existing format" do
      player = create_player()
      deck_id = "test-deck-#{System.unique_integer([:positive])}"
      match_id = "test-match-#{System.unique_integer([:positive])}"

      events = [
        # DeckUpdated establishes format as "Historic"
        build_deck_updated(%{
          player_id: player.id,
          deck_id: deck_id,
          deck_name: "Test Deck",
          format: "Historic",
          main_deck: [%{arena_id: 91_234, count: 4}],
          sideboard: []
        }),
        build_match_created(%{
          player_id: player.id,
          mtga_match_id: match_id,
          event_name: "Ladder",
          format: "ranked",
          format_type: "Constructed"
        }),
        build_deck_submitted(%{
          player_id: player.id,
          mtga_match_id: match_id,
          mtga_deck_id: deck_id,
          main_deck: [%{"arena_id" => 91_234, "count" => 4}]
        })
      ]

      project_events(DeckProjection, events)

      deck = Repo.get_by(Deck, mtga_deck_id: deck_id)
      assert deck.format == "Historic"
    end

    test "backfills Limited format on a DeckUpdated-sourced deck (draft queue)" do
      player = create_player()
      deck_id = "test-deck-#{System.unique_integer([:positive])}"
      match_id = "test-match-#{System.unique_integer([:positive])}"

      events = [
        # User built and named the deck in MTGA — MTGA tags no format.
        build_deck_updated(%{
          player_id: player.id,
          deck_id: deck_id,
          deck_name: "SoS Pick Two II 1.0",
          format: nil,
          main_deck: [%{arena_id: 91_234, count: 4}],
          sideboard: []
        }),
        build_match_created(%{
          player_id: player.id,
          mtga_match_id: match_id,
          event_name: "PickTwoDraft_SOS_20260421",
          format_type: "Limited"
        }),
        build_deck_submitted(%{
          player_id: player.id,
          mtga_match_id: match_id,
          mtga_deck_id: deck_id,
          main_deck: [%{"arena_id" => 91_234, "count" => 4}]
        })
      ]

      project_events(DeckProjection, events)

      deck = Repo.get_by(Deck, mtga_deck_id: deck_id)
      assert deck.format == "Pick Two Draft"
    end

    test "backfills plain \"Limited\" for a Direct Challenge limited deck" do
      player = create_player()
      deck_id = "test-deck-#{System.unique_integer([:positive])}"
      match_id = "test-match-#{System.unique_integer([:positive])}"

      events = [
        build_deck_updated(%{
          player_id: player.id,
          deck_id: deck_id,
          deck_name: "PickTwo I 1.0",
          format: nil,
          main_deck: [%{arena_id: 91_234, count: 4}],
          sideboard: []
        }),
        build_match_created(%{
          player_id: player.id,
          mtga_match_id: match_id,
          event_name: "DirectGameLimited",
          format_type: "Limited"
        }),
        build_deck_submitted(%{
          player_id: player.id,
          mtga_match_id: match_id,
          mtga_deck_id: deck_id,
          main_deck: [%{"arena_id" => 91_234, "count" => 4}]
        })
      ]

      project_events(DeckProjection, events)

      deck = Repo.get_by(Deck, mtga_deck_id: deck_id)
      assert deck.format == "Limited"
    end

    test "a later DeckUpdated with no format does not clobber an inferred Limited format" do
      player = create_player()
      deck_id = "test-deck-#{System.unique_integer([:positive])}"
      match_id = "test-match-#{System.unique_integer([:positive])}"

      events = [
        build_deck_updated(%{
          player_id: player.id,
          deck_id: deck_id,
          deck_name: "Draft Deck (2)",
          format: nil,
          main_deck: [%{arena_id: 91_234, count: 4}],
          sideboard: []
        }),
        build_match_created(%{
          player_id: player.id,
          mtga_match_id: match_id,
          event_name: "DirectGameLimited",
          format_type: "Limited"
        }),
        build_deck_submitted(%{
          player_id: player.id,
          mtga_match_id: match_id,
          mtga_deck_id: deck_id,
          main_deck: [%{"arena_id" => 91_234, "count" => 4}]
        }),
        # User re-saves the deck in MTGA after playing it — MTGA still sends
        # no format. This must not wipe the "Limited" the backfill inferred.
        build_deck_updated(%{
          player_id: player.id,
          deck_id: deck_id,
          deck_name: "Draft Deck (2)",
          format: nil,
          main_deck: [%{arena_id: 91_234, count: 4}],
          sideboard: []
        })
      ]

      project_events(DeckProjection, events)

      deck = Repo.get_by(Deck, mtga_deck_id: deck_id)
      assert deck.format == "Limited"
    end
  end

  describe "game_completed projection" do
    test "stores num_mulligans in game_results" do
      player = create_player()

      scenario =
        match_scenario(player,
          deck: [colors: "WU"],
          games: [
            [won: true, on_play: true, num_mulligans: 2]
          ],
          won: nil
        )

      project_events(DeckProjection, scenario)

      assert [match_result] = Repo.all(MatchResult)
      results = match_result.game_results["results"]
      assert [game] = results
      assert game["num_mulligans"] == 2
    end

    test "defaults num_mulligans to 0 when event field is nil" do
      player = create_player()

      scenario =
        match_scenario(player,
          deck: [colors: "WU"],
          games: [
            [won: true, on_play: true, num_mulligans: 0]
          ],
          won: nil
        )

      project_events(DeckProjection, scenario)

      assert [match_result] = Repo.all(MatchResult)
      results = match_result.game_results["results"]
      assert [game] = results
      assert game["num_mulligans"] == 0
    end
  end

  describe "draft deck final-build stamping" do
    test "stamps current_main_deck from the submission for a draft deck" do
      player = create_player()
      match_id = "test-match-#{System.unique_integer([:positive])}"

      events = [
        build_match_created(%{
          player_id: player.id,
          mtga_match_id: match_id,
          event_name: "QuickDraft_SOS_20260430",
          format_type: "Limited"
        }),
        build_deck_submitted(%{
          player_id: player.id,
          mtga_match_id: match_id,
          mtga_deck_id: "ignored-synthetic",
          main_deck: [%{"arena_id" => 93_811, "count" => 3}],
          sideboard: [%{"arena_id" => 93_999, "count" => 1}],
          occurred_at: ~U[2026-04-30 12:00:00Z]
        })
      ]

      project_events(DeckProjection, events)

      deck = Repo.get_by(Deck, mtga_deck_id: "draft:QuickDraft_SOS_20260430")
      assert deck.current_main_deck == %{"cards" => [%{"arena_id" => 93_811, "count" => 3}]}
      assert deck.current_sideboard == %{"cards" => [%{"arena_id" => 93_999, "count" => 1}]}
    end

    test "latest submission across matches becomes the final build" do
      player = create_player()
      m1 = "test-match-#{System.unique_integer([:positive])}"
      m2 = "test-match-#{System.unique_integer([:positive])}"

      base_match = fn id ->
        build_match_created(%{
          player_id: player.id,
          mtga_match_id: id,
          event_name: "QuickDraft_SOS_20260430",
          format_type: "Limited"
        })
      end

      events = [
        base_match.(m1),
        build_deck_submitted(%{
          player_id: player.id,
          mtga_match_id: m1,
          main_deck: [%{"arena_id" => 1, "count" => 1}],
          occurred_at: ~U[2026-04-30 12:00:00Z]
        }),
        base_match.(m2),
        build_deck_submitted(%{
          player_id: player.id,
          mtga_match_id: m2,
          main_deck: [%{"arena_id" => 2, "count" => 1}],
          occurred_at: ~U[2026-04-30 13:00:00Z]
        })
      ]

      project_events(DeckProjection, events)

      deck = Repo.get_by(Deck, mtga_deck_id: "draft:QuickDraft_SOS_20260430")
      assert deck.current_main_deck == %{"cards" => [%{"arena_id" => 2, "count" => 1}]}
    end

    test "ignores a late-arriving earlier-timestamped submission (replay order-independent)" do
      player = create_player()
      m1 = "test-match-#{System.unique_integer([:positive])}"
      m2 = "test-match-#{System.unique_integer([:positive])}"
      m3 = "test-match-#{System.unique_integer([:positive])}"

      base_match = fn id ->
        build_match_created(%{
          player_id: player.id,
          mtga_match_id: id,
          event_name: "QuickDraft_SOS_20260430",
          format_type: "Limited"
        })
      end

      # m1 at 12:00, m2 at 14:00 (latest), m3 at 11:00 (arrives last but is earliest)
      # After projection the deck must reflect arena_id 20 (the 14:00 build),
      # NOT arena_id 30 (the 11:00 build that arrived late).
      events = [
        base_match.(m1),
        build_deck_submitted(%{
          player_id: player.id,
          mtga_match_id: m1,
          main_deck: [%{"arena_id" => 10, "count" => 1}],
          occurred_at: ~U[2026-04-30 12:00:00Z]
        }),
        base_match.(m2),
        build_deck_submitted(%{
          player_id: player.id,
          mtga_match_id: m2,
          main_deck: [%{"arena_id" => 20, "count" => 1}],
          occurred_at: ~U[2026-04-30 14:00:00Z]
        }),
        base_match.(m3),
        build_deck_submitted(%{
          player_id: player.id,
          mtga_match_id: m3,
          main_deck: [%{"arena_id" => 30, "count" => 1}],
          occurred_at: ~U[2026-04-30 11:00:00Z]
        })
      ]

      project_events(DeckProjection, events)

      deck = Repo.get_by(Deck, mtga_deck_id: "draft:QuickDraft_SOS_20260430")
      assert deck.current_main_deck == %{"cards" => [%{"arena_id" => 20, "count" => 1}]}
    end

    test "does NOT overwrite a constructed deck's builder card list" do
      player = create_player()
      deck_id = "test-deck-#{System.unique_integer([:positive])}"
      match_id = "test-match-#{System.unique_integer([:positive])}"

      events = [
        build_deck_updated(%{
          player_id: player.id,
          deck_id: deck_id,
          format: "Standard",
          main_deck: [%{arena_id: 91_234, count: 4}],
          sideboard: []
        }),
        build_match_created(%{
          player_id: player.id,
          mtga_match_id: match_id,
          event_name: "Ladder",
          format_type: "Constructed"
        }),
        build_deck_submitted(%{
          player_id: player.id,
          mtga_match_id: match_id,
          mtga_deck_id: deck_id,
          main_deck: [
            %{"arena_id" => 91_234, "count" => 4},
            %{"arena_id" => 99_999, "count" => 1}
          ]
        })
      ]

      project_events(DeckProjection, events)

      deck = Repo.get_by(Deck, mtga_deck_id: deck_id)
      assert deck.current_main_deck == %{"cards" => [%{"arena_id" => 91_234, "count" => 4}]}
    end
  end

  describe "deck_inventory projection" do
    test "inserts a stub deck row for each deck in the snapshot" do
      events = [
        build_deck_inventory(
          decks: [
            %{deck_id: "inv-aaa", name: "Forest's Might", format: "Explorer"},
            %{deck_id: "inv-bbb", name: "Dragon's Fire", format: "Historic"}
          ]
        )
      ]

      project_events(DeckProjection, events)

      a = Scry2.Decks.get_deck("inv-aaa")
      b = Scry2.Decks.get_deck("inv-bbb")
      assert a.current_name == "Forest's Might"
      assert a.format == "Explorer"
      assert a.current_main_deck == %{}
      assert b.current_name == "Dragon's Fire"
      assert b.format == "Historic"
    end

    test "a later inventory snapshot does not clobber a deck's card list or format" do
      # DeckUpdated (edit) establishes cards + format on deck "inv-ccc";
      # a subsequent inventory snapshot carries a new name and nil format.
      events = [
        build_deck_updated(%{
          deck_id: "inv-ccc",
          deck_name: "Edited Deck",
          format: "Historic",
          main_deck: [%{arena_id: 91_234, count: 4}]
        }),
        build_deck_inventory(decks: [%{deck_id: "inv-ccc", name: "Renamed In MTGA", format: nil}])
      ]

      project_events(DeckProjection, events)

      deck = Scry2.Decks.get_deck("inv-ccc")
      assert deck.current_name == "Renamed In MTGA"
      assert deck.format == "Historic"
      assert deck.current_main_deck == %{"cards" => [%{"arena_id" => 91_234, "count" => 4}]}
    end

    test "is idempotent — replaying the same snapshot yields identical state" do
      events = [
        build_deck_inventory(decks: [%{deck_id: "inv-ddd", name: "Deck", format: "Standard"}])
      ]

      project_events(DeckProjection, events)
      first = Scry2.Decks.get_deck("inv-ddd")

      project_events(DeckProjection, events)
      second = Scry2.Decks.get_deck("inv-ddd")

      assert first.current_name == second.current_name
      assert first.format == second.format
      assert Repo.aggregate(Scry2.Decks.Deck, :count) == 1
    end
  end

  describe "deck_deleted projection" do
    test "sets archived=true on the matching deck" do
      player = create_player()
      deck_id = "deck-to-delete-#{System.unique_integer([:positive])}"

      events = [
        build_deck_updated(%{
          player_id: player.id,
          deck_id: deck_id,
          deck_name: "Goldfish Brew",
          format: "Standard",
          main_deck: [%{arena_id: 91_234, count: 4}],
          sideboard: []
        }),
        build_deck_deleted(%{mtga_deck_id: deck_id})
      ]

      project_events(DeckProjection, events)

      deck = Repo.get_by(Deck, mtga_deck_id: deck_id)
      assert deck.archived == true
      assert deck.current_name == "Goldfish Brew"
    end

    test "is a no-op when the deck row does not exist (replay safety)" do
      events = [build_deck_deleted(%{mtga_deck_id: "unknown-deck"})]

      project_events(DeckProjection, events)

      refute Repo.get_by(Deck, mtga_deck_id: "unknown-deck")
    end
  end

  describe "archetype stamping" do
    defp install_burn_definition do
      Scry2.Metagame.replace_definitions!("Standard", %{
        definitions: [
          %{
            key: "Burn",
            kind: "archetype",
            name: "Burn",
            include_color_in_name: true,
            conditions: [%{"type" => "InMainboard", "cards" => ["Lightning Bolt"]}],
            variants: [],
            common_cards: []
          }
        ],
        overrides: []
      })
    end

    test "DeckUpdated stamps the classified archetype on the deck and its version" do
      install_burn_definition()
      bolt = create_card(name: "Lightning Bolt", color_identity: "R")
      mountain = create_card(name: "Mountain", color_identity: "R", is_land: true)
      player = create_player()
      deck_id = "test-deck-#{System.unique_integer([:positive])}"

      project_events(DeckProjection, [
        build_deck_updated(%{
          player_id: player.id,
          deck_id: deck_id,
          format: "Standard",
          main_deck: [
            %{arena_id: bolt.arena_id, count: 4},
            %{arena_id: mountain.arena_id, count: 16}
          ],
          sideboard: []
        })
      ])

      deck = Scry2.Decks.get_deck(deck_id)
      assert deck.archetype_name == "Mono-Red Burn"
      assert deck.archetype_fallback == false

      assert [version] = Scry2.Decks.get_deck_versions(deck_id)
      assert version.archetype_name == "Mono-Red Burn"
    end

    test "non-Standard decks are not classified" do
      install_burn_definition()
      bolt = create_card(name: "Lightning Bolt", color_identity: "R")
      player = create_player()
      deck_id = "test-deck-#{System.unique_integer([:positive])}"

      project_events(DeckProjection, [
        build_deck_updated(%{
          player_id: player.id,
          deck_id: deck_id,
          format: "Historic",
          main_deck: [%{arena_id: bolt.arena_id, count: 4}],
          sideboard: []
        })
      ])

      assert Scry2.Decks.get_deck(deck_id).archetype_name == nil
    end

    test "reclassify_archetypes! re-stamps decks and versions" do
      bolt = create_card(name: "Lightning Bolt", color_identity: "R")
      player = create_player()
      deck_id = "test-deck-#{System.unique_integer([:positive])}"

      project_events(DeckProjection, [
        build_deck_updated(%{
          player_id: player.id,
          deck_id: deck_id,
          format: "Standard",
          main_deck: [%{arena_id: bolt.arena_id, count: 4}],
          sideboard: []
        })
      ])

      assert Scry2.Decks.get_deck(deck_id).archetype_name == nil

      install_burn_definition()

      assert Scry2.Decks.reclassify_archetypes!() == 2

      assert Scry2.Decks.get_deck(deck_id).archetype_name == "Burn"
      assert [version] = Scry2.Decks.get_deck_versions(deck_id)
      assert version.archetype_name == "Burn"
    end
  end
end
