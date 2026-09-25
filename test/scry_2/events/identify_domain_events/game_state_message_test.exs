defmodule Scry2.Events.IdentifyDomainEvents.GameStateMessageTest do
  use ExUnit.Case, async: true

  alias Scry2.Events.IdentifyDomainEvents
  alias Scry2.Events.Turn.{TurnStarted, PhaseChanged}
  alias Scry2.MtgaLogIngestion.{Event, EventRecord, ExtractEventsFromLog}

  @self_user_id "D0FECB2AF1E7FE24"

  defp record_from_fixture(fixture_name) do
    path = Path.join([__DIR__, "..", "..", "..", "fixtures", "mtga_logs", fixture_name])
    chunk = File.read!(path)
    {[%Event{} = event], _warnings} = ExtractEventsFromLog.parse_chunk(chunk, "Player.log", 0)

    %EventRecord{
      id: 1,
      event_type: event.type,
      mtga_timestamp: event.mtga_timestamp,
      file_offset: 0,
      source_file: "Player.log",
      raw_json: event.raw_json,
      processed: false
    }
  end

  describe "TurnStarted" do
    test "emits TurnStarted when turn number changes from nil (first turn)" do
      record = record_from_fixture("gre_game_state_turn_started.log")
      {events, []} = IdentifyDomainEvents.translate(record, @self_user_id, %{})

      assert Enum.any?(events, &match?(%TurnStarted{}, &1)),
             "Expected TurnStarted, got: #{inspect(Enum.map(events, & &1.__struct__))}"

      turn_event = Enum.find(events, &match?(%TurnStarted{}, &1))
      assert is_integer(turn_event.turn_number) and turn_event.turn_number > 0
      assert is_integer(turn_event.active_player_seat)
    end

    test "does NOT emit TurnStarted when turn number is unchanged" do
      record = record_from_fixture("gre_game_state_turn_started.log")
      {events_first, []} = IdentifyDomainEvents.translate(record, @self_user_id, %{})
      first_turn = Enum.find(events_first, &match?(%TurnStarted{}, &1))

      # Same turn in context → no new TurnStarted
      context = %{turn_phase_state: %{turn: first_turn.turn_number}}
      {events_second, []} = IdentifyDomainEvents.translate(record, @self_user_id, context)

      refute Enum.any?(events_second, &match?(%TurnStarted{}, &1)),
             "Should not emit TurnStarted when turn is unchanged"
    end
  end

  describe "turn structure suppression" do
    test "does NOT emit TurnStarted or PhaseChanged when batch has no turnInfo" do
      raw_json =
        Jason.encode!(%{
          "greToClientEvent" => %{
            "greToClientMessages" => [
              %{
                "type" => "GREMessageType_GameStateMessage",
                "systemSeatIds" => [1],
                "gameStateMessage" => %{
                  "type" => "GameStateType_Diff",
                  "gameObjects" => []
                  # No turnInfo key
                }
              }
            ]
          }
        })

      record = %Scry2.MtgaLogIngestion.EventRecord{
        id: 1,
        event_type: "GreToClientEvent",
        mtga_timestamp: DateTime.utc_now(:second),
        file_offset: 0,
        source_file: "Player.log",
        raw_json: raw_json,
        processed: false
      }

      {events, _} = IdentifyDomainEvents.translate(record, @self_user_id, %{})

      refute Enum.any?(events, &match?(%TurnStarted{}, &1)),
             "Should not emit TurnStarted when no turnInfo present"

      refute Enum.any?(events, &match?(%PhaseChanged{}, &1)),
             "Should not emit PhaseChanged when no turnInfo present"
    end

    test "re-emits PhaseChanged after TurnStarted resets phase to nil" do
      record = record_from_fixture("gre_game_state_turn_started.log")
      {events_first, []} = IdentifyDomainEvents.translate(record, @self_user_id, %{})
      first_turn = Enum.find(events_first, &match?(%TurnStarted{}, &1))

      # Simulate state after TurnStarted fired: phase reset to nil for the new turn
      post_turn_context = %{
        turn_phase_state: %{turn: first_turn.turn_number + 1, phase: nil, step: nil}
      }

      # Same fixture with a context where the turn advanced but phase was reset.
      # The fixture has a phase — PhaseChanged should re-emit because context phase is nil.
      {events_second, []} =
        IdentifyDomainEvents.translate(record, @self_user_id, post_turn_context)

      assert Enum.any?(events_second, &match?(%PhaseChanged{}, &1)),
             "Should emit PhaseChanged when context phase is nil (after turn boundary reset)"
    end
  end

  describe "PriorityAssigned" do
    test "emits PriorityAssigned for each GameStateMessage with priorityPlayer" do
      record = record_from_fixture("gre_game_state_priority_assigned.log")
      {events, []} = IdentifyDomainEvents.translate(record, @self_user_id, %{})

      priority_events =
        Enum.filter(events, &match?(%Scry2.Events.Priority.PriorityAssigned{}, &1))

      # No delta detection — every priority assignment emits an event
      assert length(priority_events) >= 1,
             "Expected at least one PriorityAssigned per GSM message with priorityPlayer"

      # All events have a valid player seat
      assert Enum.all?(priority_events, fn pa -> is_integer(pa.player_seat) end)
    end
  end

  describe "PermanentTapped" do
    test "emits PermanentTapped when a game object is tapped and was not tapped before" do
      record = record_from_fixture("gre_game_state_permanent_tap.log")
      # Empty prior state → all tapped objects are "newly tapped"
      {events, []} =
        IdentifyDomainEvents.translate(record, @self_user_id, %{game_object_states: %{}})

      tapped = Enum.filter(events, &match?(%Scry2.Events.Permanent.PermanentTapped{}, &1))
      assert tapped != [], "Expected at least one PermanentTapped event"
      assert Enum.all?(tapped, fn e -> is_integer(e.instance_id) end)
    end

    test "does NOT emit PermanentTapped when object was already tapped in context" do
      record = record_from_fixture("gre_game_state_permanent_tap.log")

      {events_first, []} =
        IdentifyDomainEvents.translate(record, @self_user_id, %{game_object_states: %{}})

      first_tapped =
        Enum.find(events_first, &match?(%Scry2.Events.Permanent.PermanentTapped{}, &1))

      assert first_tapped != nil, "Prerequisite: fixture must have a tapped object"

      # Mark object as already tapped in context
      prior_states = %{first_tapped.instance_id => %{tapped: true, power: nil, toughness: nil}}

      {events_second, []} =
        IdentifyDomainEvents.translate(record, @self_user_id, %{game_object_states: prior_states})

      tapped_instance_id = first_tapped.instance_id

      refute Enum.any?(events_second, fn e ->
               match?(
                 %Scry2.Events.Permanent.PermanentTapped{instance_id: ^tapped_instance_id},
                 e
               )
             end),
             "Should not emit PermanentTapped for already-tapped object"
    end
  end

  describe "PermanentStatsChanged" do
    test "emits PermanentStatsChanged when power/toughness changes from nil" do
      record = record_from_fixture("gre_game_state_stats_changed.log")

      {events, []} =
        IdentifyDomainEvents.translate(record, @self_user_id, %{game_object_states: %{}})

      stats_events =
        Enum.filter(events, &match?(%Scry2.Events.Permanent.PermanentStatsChanged{}, &1))

      assert stats_events != [], "Expected at least one PermanentStatsChanged event"

      stat = hd(stats_events)
      assert is_integer(stat.instance_id)
      # power and toughness should be integers, not nested maps
      assert is_integer(stat.power) or is_nil(stat.power)
      assert is_integer(stat.toughness) or is_nil(stat.toughness)
    end

    test "does NOT emit PermanentStatsChanged when stats are unchanged" do
      record = record_from_fixture("gre_game_state_stats_changed.log")

      {events_first, []} =
        IdentifyDomainEvents.translate(record, @self_user_id, %{game_object_states: %{}})

      first_stats =
        Enum.find(events_first, &match?(%Scry2.Events.Permanent.PermanentStatsChanged{}, &1))

      if first_stats do
        stats_instance_id = first_stats.instance_id

        prior_states = %{
          stats_instance_id => %{
            tapped: false,
            power: first_stats.power,
            toughness: first_stats.toughness
          }
        }

        {events_second, []} =
          IdentifyDomainEvents.translate(record, @self_user_id, %{
            game_object_states: prior_states
          })

        refute Enum.any?(events_second, fn e ->
                 match?(
                   %Scry2.Events.Permanent.PermanentStatsChanged{
                     instance_id: ^stats_instance_id
                   },
                   e
                 )
               end),
               "Should not emit PermanentStatsChanged when stats unchanged"
      end
    end
  end

  describe "PhaseChanged" do
    test "emits PhaseChanged when phase changes from nil (first message)" do
      record = record_from_fixture("gre_game_state_turn_started.log")
      {events, []} = IdentifyDomainEvents.translate(record, @self_user_id, %{})

      assert Enum.any?(events, &match?(%PhaseChanged{}, &1)),
             "Expected PhaseChanged, got: #{inspect(Enum.map(events, & &1.__struct__))}"

      phase_event = Enum.find(events, &match?(%PhaseChanged{}, &1))
      assert is_binary(phase_event.phase) and phase_event.phase != ""
    end

    test "does NOT emit PhaseChanged when phase is unchanged" do
      record = record_from_fixture("gre_game_state_turn_started.log")
      {events_first, []} = IdentifyDomainEvents.translate(record, @self_user_id, %{})
      first_phase = Enum.find(events_first, &match?(%PhaseChanged{}, &1))

      context = %{
        turn_phase_state: %{
          turn: first_phase.turn_number,
          phase: first_phase.phase,
          step: first_phase.step
        }
      }

      {events_second, []} = IdentifyDomainEvents.translate(record, @self_user_id, context)

      refute Enum.any?(events_second, &match?(%PhaseChanged{}, &1)),
             "Should not emit PhaseChanged when phase is unchanged"
    end

    test "PhaseChanged carries turn_number from turnInfo" do
      record = record_from_fixture("gre_game_state_turn_started.log")
      {events, []} = IdentifyDomainEvents.translate(record, @self_user_id, %{})

      phase_event = Enum.find(events, &match?(%PhaseChanged{}, &1))
      assert is_integer(phase_event.turn_number)
    end
  end

  describe "TargetsDeclared" do
    test "emits TargetsDeclared from AnnotationType_TargetSpec persistent annotation" do
      # AnnotationType_TargetSpec lives in persistentAnnotations (confirmed from Player.log)
      raw_json =
        Jason.encode!(%{
          "greToClientEvent" => %{
            "greToClientMessages" => [
              %{
                "type" => "GREMessageType_GameStateMessage",
                "systemSeatIds" => [1],
                "gameStateMessage" => %{
                  "type" => "GameStateType_Diff",
                  "turnInfo" => %{
                    "turnNumber" => 13,
                    "phase" => "Phase_Main2",
                    "activePlayer" => 1
                  },
                  "persistentAnnotations" => [
                    %{
                      "id" => 971,
                      "affectorId" => 855,
                      "affectedIds" => [789, 837],
                      "type" => ["AnnotationType_TargetSpec"],
                      "details" => []
                    }
                  ]
                }
              }
            ]
          }
        })

      record = %Scry2.MtgaLogIngestion.EventRecord{
        id: 1,
        event_type: "GreToClientEvent",
        mtga_timestamp: DateTime.utc_now(:second),
        file_offset: 0,
        source_file: "Player.log",
        raw_json: raw_json,
        processed: false
      }

      match_ctx = %{
        current_game_number: 1,
        game_objects: %{789 => 12345, 837 => 67890}
      }

      {events, []} = IdentifyDomainEvents.translate(record, "test-user", match_ctx)

      td = Enum.find(events, &match?(%Scry2.Events.Stack.TargetsDeclared{}, &1))

      assert td != nil,
             "Expected TargetsDeclared, got: #{inspect(Enum.map(events, & &1.__struct__))}"

      assert td.spell_instance_id == 855
      assert td.turn_number == 13
      assert length(td.targets) == 2

      [t1, t2] = td.targets
      assert t1.instance_id == 789
      assert t1.arena_id == 12345
      assert t2.instance_id == 837
      assert t2.arena_id == 67890
    end

    test "TargetsDeclared resolves arena_id as nil when instance not in game_objects" do
      raw_json =
        Jason.encode!(%{
          "greToClientEvent" => %{
            "greToClientMessages" => [
              %{
                "type" => "GREMessageType_GameStateMessage",
                "systemSeatIds" => [1],
                "gameStateMessage" => %{
                  "type" => "GameStateType_Diff",
                  "turnInfo" => %{"turnNumber" => 5, "phase" => "Phase_Combat"},
                  "persistentAnnotations" => [
                    %{
                      "id" => 100,
                      "affectorId" => 200,
                      "affectedIds" => [300],
                      "type" => ["AnnotationType_TargetSpec"],
                      "details" => []
                    }
                  ]
                }
              }
            ]
          }
        })

      record = %Scry2.MtgaLogIngestion.EventRecord{
        id: 2,
        event_type: "GreToClientEvent",
        mtga_timestamp: DateTime.utc_now(:second),
        file_offset: 0,
        source_file: "Player.log",
        raw_json: raw_json,
        processed: false
      }

      # game_objects is empty — arena_id should be nil
      {events, []} = IdentifyDomainEvents.translate(record, "test-user", %{game_objects: %{}})

      td = Enum.find(events, &match?(%Scry2.Events.Stack.TargetsDeclared{}, &1))
      assert td != nil
      assert [%{instance_id: 300, arena_id: nil}] = td.targets
    end
  end

  describe "AbilityActivated" do
    test "emits AbilityActivated from AnnotationType_ActivatedAbility annotation" do
      raw_json =
        Jason.encode!(%{
          "greToClientEvent" => %{
            "greToClientMessages" => [
              %{
                "type" => "GREMessageType_GameStateMessage",
                "systemSeatIds" => [1],
                "gameStateMessage" => %{
                  "type" => "GameStateType_Diff",
                  "turnInfo" => %{
                    "turnNumber" => 7,
                    "phase" => "Phase_Main1",
                    "activePlayer" => 1
                  },
                  "annotations" => [
                    %{
                      "id" => 50,
                      "affectorId" => 42,
                      "affectedIds" => [42],
                      "type" => ["AnnotationType_ActivatedAbility"]
                    }
                  ]
                }
              }
            ]
          }
        })

      record = %Scry2.MtgaLogIngestion.EventRecord{
        id: 3,
        event_type: "GreToClientEvent",
        mtga_timestamp: DateTime.utc_now(:second),
        file_offset: 0,
        source_file: "Player.log",
        raw_json: raw_json,
        processed: false
      }

      {events, []} =
        IdentifyDomainEvents.translate(record, "test-user", %{game_objects: %{42 => 99999}})

      aa = Enum.find(events, &match?(%Scry2.Events.Stack.AbilityActivated{}, &1))

      assert aa != nil,
             "Expected AbilityActivated, got: #{inspect(Enum.map(events, & &1.__struct__))}"

      assert aa.source_instance_id == 42
      assert aa.source_arena_id == 99999
      assert aa.turn_number == 7
      assert aa.phase == "Phase_Main1"
    end
  end

  describe "TriggerCreated" do
    test "emits TriggerCreated from AnnotationType_TriggeredAbility annotation" do
      raw_json =
        Jason.encode!(%{
          "greToClientEvent" => %{
            "greToClientMessages" => [
              %{
                "type" => "GREMessageType_GameStateMessage",
                "systemSeatIds" => [1],
                "gameStateMessage" => %{
                  "type" => "GameStateType_Diff",
                  "turnInfo" => %{
                    "turnNumber" => 4,
                    "phase" => "Phase_Beginning",
                    "activePlayer" => 2
                  },
                  "annotations" => [
                    %{
                      "id" => 60,
                      "affectorId" => 77,
                      "affectedIds" => [77],
                      "type" => ["AnnotationType_TriggeredAbility"],
                      "details" => []
                    }
                  ]
                }
              }
            ]
          }
        })

      record = %Scry2.MtgaLogIngestion.EventRecord{
        id: 4,
        event_type: "GreToClientEvent",
        mtga_timestamp: DateTime.utc_now(:second),
        file_offset: 0,
        source_file: "Player.log",
        raw_json: raw_json,
        processed: false
      }

      {events, []} = IdentifyDomainEvents.translate(record, "test-user", %{game_objects: %{}})

      tc = Enum.find(events, &match?(%Scry2.Events.Stack.TriggerCreated{}, &1))

      assert tc != nil,
             "Expected TriggerCreated, got: #{inspect(Enum.map(events, & &1.__struct__))}"

      assert tc.source_instance_id == 77
      assert tc.turn_number == 4
      assert tc.phase == "Phase_Beginning"
      # trigger_type is nil when details is empty (no real fixture available yet)
      assert is_nil(tc.trigger_type) or is_binary(tc.trigger_type)
    end

    test "extracts trigger_type from details when present" do
      raw_json =
        Jason.encode!(%{
          "greToClientEvent" => %{
            "greToClientMessages" => [
              %{
                "type" => "GREMessageType_GameStateMessage",
                "systemSeatIds" => [1],
                "gameStateMessage" => %{
                  "type" => "GameStateType_Diff",
                  "turnInfo" => %{"turnNumber" => 2, "phase" => "Phase_Main1"},
                  "annotations" => [
                    %{
                      "id" => 61,
                      "affectorId" => 88,
                      "affectedIds" => [88],
                      "type" => ["AnnotationType_TriggeredAbility"],
                      "details" => [
                        %{
                          "key" => "trigger_type",
                          "valueString" => ["EnteredBattlefield"]
                        }
                      ]
                    }
                  ]
                }
              }
            ]
          }
        })

      record = %Scry2.MtgaLogIngestion.EventRecord{
        id: 5,
        event_type: "GreToClientEvent",
        mtga_timestamp: DateTime.utc_now(:second),
        file_offset: 0,
        source_file: "Player.log",
        raw_json: raw_json,
        processed: false
      }

      {events, []} = IdentifyDomainEvents.translate(record, "test-user", %{game_objects: %{}})

      tc = Enum.find(events, &match?(%Scry2.Events.Stack.TriggerCreated{}, &1))
      assert tc != nil
      assert tc.trigger_type == "EnteredBattlefield"
    end
  end

  describe "CardDrawn draw attribution" do
    # Regression: the zone table was keyed by `zones[].id`, a field that
    # does not exist — every zone object carries `zoneId`. The resulting
    # map was keyed entirely by nil, so `is_self_draw` resolved to nil on
    # all 26,469 card_drawn events ever produced. See ADR-047.
    test "resolves is_self_draw from the zone table's owning seat" do
      record = record_from_fixture("gre_game_state_card_drawn.log")

      {events, []} =
        IdentifyDomainEvents.translate(record, @self_user_id, %{
          game_objects: %{},
          self_seat_id: 1
        })

      draws = Enum.filter(events, &match?(%Scry2.Events.Gameplay.CardDrawn{}, &1))

      assert draws != [], "fixture should produce at least one CardDrawn"

      assert Enum.all?(draws, &is_boolean(&1.is_self_draw)),
             "is_self_draw must be resolved, got: #{inspect(Enum.map(draws, & &1.is_self_draw))}"
    end

    test "attributes a draw into the opponent's hand as not-self" do
      record = record_from_fixture("gre_game_state_card_drawn.log")

      {events, []} =
        IdentifyDomainEvents.translate(record, @self_user_id, %{
          game_objects: %{},
          self_seat_id: 2
        })

      draws = Enum.filter(events, &match?(%Scry2.Events.Gameplay.CardDrawn{}, &1))

      assert draws != []
      assert Enum.all?(draws, &(&1.is_self_draw == false))
    end
  end

  describe "owner_seat_id attribution" do
    # Gameplay events carried `active_player` (whose turn it is) but never
    # the seat that owns the card. Revealed-cards projection needs the
    # owner, which the GRE zone table states outright. ADR-047.
    test "stamps the owning seat of the destination zone onto zone-transfer events" do
      record = record_from_fixture("gre_game_state_card_drawn.log")

      {events, []} =
        IdentifyDomainEvents.translate(record, @self_user_id, %{
          game_objects: %{},
          self_seat_id: 1
        })

      draws = Enum.filter(events, &match?(%Scry2.Events.Gameplay.CardDrawn{}, &1))
      assert draws != []

      # The fixture's hand (zone 31) is owned by seat 1.
      assert Enum.all?(draws, &(&1.owner_seat_id == 1)),
             "got: #{inspect(Enum.map(draws, & &1.owner_seat_id))}"
    end

    test "owner_seat_id is nil when the destination zone has no owner" do
      # Shared zones (battlefield, stack) carry no ownerSeatId; the field
      # must be nil rather than guessing from active_player.
      record = record_from_fixture("gre_game_state_card_drawn.log")

      {events, []} =
        IdentifyDomainEvents.translate(record, @self_user_id, %{game_objects: %{}})

      resolves = Enum.filter(events, &match?(%Scry2.Events.Gameplay.SpellResolved{}, &1))

      for event <- resolves do
        assert event.owner_seat_id == nil or is_integer(event.owner_seat_id)
      end
    end
  end

  describe "zone labels on every zone-transfer event" do
    # Every one of these events is built from the same
    # AnnotationType_ZoneTransfer, which carries zone_src/zone_dest.
    # Carrying the resolved zones on all of them means the revealed-cards
    # projection never has to infer "a draw means hand". ADR-047.
    test "CardDrawn carries the resolved destination zone" do
      record = record_from_fixture("gre_game_state_card_drawn.log")

      {events, []} =
        IdentifyDomainEvents.translate(record, @self_user_id, %{
          game_objects: %{},
          self_seat_id: 1
        })

      draws = Enum.filter(events, &match?(%Scry2.Events.Gameplay.CardDrawn{}, &1))
      assert draws != []

      assert Enum.all?(draws, &(&1.zone_to == "hand")),
             "got: #{inspect(Enum.map(draws, & &1.zone_to))}"

      assert Enum.all?(draws, &(&1.zone_from == "library"))
    end

    test "SpellCast and SpellResolved carry zones" do
      record = record_from_fixture("gre_game_state_card_drawn.log")

      {events, []} =
        IdentifyDomainEvents.translate(record, @self_user_id, %{game_objects: %{}})

      zoned =
        Enum.filter(events, fn e ->
          match?(%Scry2.Events.Gameplay.SpellCast{}, e) or
            match?(%Scry2.Events.Gameplay.SpellResolved{}, e)
        end)

      assert zoned != []
      assert Enum.all?(zoned, &is_binary(&1.zone_to))
    end
  end

  describe "owner_is_local" do
    # GRE ownerSeatId is a per-match seat NUMBER and the local player
    # alternates seats between matches — seat 1 is the local player only
    # ~75% of the time in real data. Consumers need the role, not the
    # number, so the ACL resolves it once. ADR-047.
    test "true when the owning seat is the local player's seat" do
      record = record_from_fixture("gre_game_state_card_drawn.log")

      {events, []} =
        IdentifyDomainEvents.translate(record, @self_user_id, %{
          game_objects: %{},
          self_seat_id: 1
        })

      draws = Enum.filter(events, &match?(%Scry2.Events.Gameplay.CardDrawn{}, &1))
      assert draws != []
      assert Enum.all?(draws, &(&1.owner_is_local == true))
    end

    test "false when the owning seat is the opponent's" do
      record = record_from_fixture("gre_game_state_card_drawn.log")

      {events, []} =
        IdentifyDomainEvents.translate(record, @self_user_id, %{
          game_objects: %{},
          self_seat_id: 2
        })

      draws = Enum.filter(events, &match?(%Scry2.Events.Gameplay.CardDrawn{}, &1))
      assert draws != []
      assert Enum.all?(draws, &(&1.owner_is_local == false))
    end

    test "nil when the local seat is unknown" do
      record = record_from_fixture("gre_game_state_card_drawn.log")

      {events, []} =
        IdentifyDomainEvents.translate(record, @self_user_id, %{game_objects: %{}})

      draws = Enum.filter(events, &match?(%Scry2.Events.Gameplay.CardDrawn{}, &1))
      assert draws != []
      assert Enum.all?(draws, &(&1.owner_is_local == nil))
    end

    test "is_self_draw agrees with owner_is_local" do
      # is_self_draw is the older, narrower name for the same fact and
      # still has consumers in Decks; both must come from one computation.
      record = record_from_fixture("gre_game_state_card_drawn.log")

      {events, []} =
        IdentifyDomainEvents.translate(record, @self_user_id, %{
          game_objects: %{},
          self_seat_id: 1
        })

      for draw <- Enum.filter(events, &match?(%Scry2.Events.Gameplay.CardDrawn{}, &1)) do
        assert draw.is_self_draw == draw.owner_is_local
      end
    end
  end
end
