defmodule Scry2.Events.IdentifyDomainEvents.GameStateMessage do
  @moduledoc """
  Translator for GREMessageType_GameStateMessage messages within GreToClientEvent.

  Handles the bulk of in-game event extraction:
  - GameCompleted (MatchState_GameComplete)
  - DieRolled (DieRollResultsResp)
  - MulliganOffered (MulliganReq)
  - TurnStarted / PhaseChanged (turnInfo delta detection — emitted when turn number or phase changes)
  - Turn actions from annotations (ZoneTransfer, DamageDealt, ModifiedLife, etc.)

  Called by the coordinator with pre-decoded `messages` (the inner
  `greToClientMessages` list), not a raw `EventRecord`. See
  `IdentifyDomainEvents` for the envelope decoding.
  """

  alias Scry2.Events.Gameplay.{
    CardDrawn,
    CardExiled,
    CombatDamageDealt,
    CounterAdded,
    LandPlayed,
    LifeTotalChanged,
    MulliganOffered,
    PermanentDestroyed,
    SpellCast,
    SpellResolved,
    TokenCreated,
    ZoneChanged
  }

  alias Scry2.Events.IdentifyDomainEvents.Helpers
  alias Scry2.Events.Match.{DieRolled, GameCompleted}
  alias Scry2.Events.Permanent.{PermanentStatsChanged, PermanentTapped, PermanentUntapped}
  alias Scry2.Events.Priority.PriorityAssigned
  alias Scry2.Events.Stack.{AbilityActivated, TargetsDeclared, TriggerCreated}
  alias Scry2.Events.Turn.{PhaseChanged, TurnStarted}

  @doc """
  Builds all GameStateMessage-derived domain events from a GRE message batch.

  Returns a flat list of domain events (may be empty).

  `player_seat` is resolved once per GRE batch by the caller.
  """
  def build(messages, match_id, occurred_at, player_seat, match_context) do
    [
      maybe_build_die_roll_completed(
        messages,
        match_id,
        occurred_at,
        player_seat,
        match_context[:current_game_number]
      ),
      maybe_build_game_completed(messages, match_id, occurred_at, player_seat),
      build_mulligan_offered(messages, match_id, occurred_at, match_context),
      build_turn_structure_events(messages, match_id, occurred_at, match_context),
      build_priority_assigned_events(messages, match_id, occurred_at, match_context),
      build_permanent_state_events(messages, match_id, occurred_at, match_context),
      build_turn_actions(messages, match_id, occurred_at, match_context)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  # ── GameCompleted ──────────────────────────────────────────────────────

  # GameStateMessage with matchState "MatchState_GameComplete" carries
  # per-game results including winner, game number, and player stats.
  #
  # MTGA GRE protocol: GreToClientEvent is sent TO the player. Each GRE
  # message's `systemSeatIds` indicates which seat(s) it's addressed to.
  # Since this is the player's client feed, `systemSeatIds[0]` IS the
  # player's seat number. We use it to determine which `players[]` entry
  # is "self" vs "opponent". Without this, hardcoding seat 1 inverts
  # won/lost and swaps mulligan counts when the player is seat 2.
  # `player_seat` is resolved once per GRE batch by the caller.
  defp maybe_build_game_completed(messages, match_id, occurred_at, player_seat)
       when is_binary(match_id) do
    Enum.find_value(messages, fn msg ->
      with true <- Helpers.game_state_message?(msg),
           gsm when is_map(gsm) <- Helpers.extract_game_state(msg),
           game_info when is_map(game_info) <- gsm["gameInfo"],
           "MatchState_GameComplete" <- game_info["matchState"] do
        results = game_info["results"] || []
        game_result = Enum.find(results, &(&1["scope"] == "MatchScope_Game"))
        players = gsm["players"] || []
        self_player = Enum.find(players, &(&1["systemSeatNumber"] == player_seat))
        opponent_player = Enum.find(players, &(&1["systemSeatNumber"] != player_seat))
        self_team = self_player && self_player["teamId"]

        %GameCompleted{
          mtga_match_id: match_id,
          game_number: game_info["gameNumber"],
          on_play: nil,
          won: game_result && self_team && game_result["winningTeamId"] == self_team,
          num_mulligans: self_player && self_player["mulliganCount"],
          opponent_num_mulligans: opponent_player && opponent_player["mulliganCount"],
          num_turns: self_player && self_player["turnNumber"],
          self_life_total: self_player && self_player["lifeTotal"],
          opponent_life_total: opponent_player && opponent_player["lifeTotal"],
          win_reason: game_result && game_result["reason"],
          super_format: game_info["superFormat"],
          occurred_at: occurred_at
        }
      else
        _ -> nil
      end
    end)
  end

  defp maybe_build_game_completed(_messages, _match_id, _occurred_at, _player_seat), do: nil

  # ── DieRolled ──────────────────────────────────────────────────────────

  # DieRollResultsResp carries both players' roll values. The higher
  # roll wins and chooses to play first (virtually always chooses play).
  # `player_seat` is resolved once per GRE batch by the caller.
  defp maybe_build_die_roll_completed(messages, match_id, occurred_at, player_seat, game_number)
       when is_binary(match_id) do
    case Helpers.find_gre_message(messages, "GREMessageType_DieRollResultsResp") do
      %{"dieRollResultsResp" => %{"playerDieRolls" => rolls}} ->
        self_roll_entry = Enum.find(rolls, &(&1["systemSeatId"] == player_seat))
        opponent_roll_entry = Enum.find(rolls, &(&1["systemSeatId"] != player_seat))

        if self_roll_entry && opponent_roll_entry do
          self_roll = self_roll_entry["rollValue"]
          opponent_roll = opponent_roll_entry["rollValue"]

          %DieRolled{
            mtga_match_id: match_id,
            game_number: game_number,
            self_roll: self_roll,
            opponent_roll: opponent_roll,
            self_goes_first: self_roll > opponent_roll,
            occurred_at: occurred_at
          }
        end

      _ ->
        nil
    end
  end

  defp maybe_build_die_roll_completed(
         _messages,
         _match_id,
         _occurred_at,
         _player_seat,
         _game_number
       ),
       do: nil

  # ── MulliganOffered ───────────────────────────────────────────────────

  # MulliganReq messages offer a mulligan decision to a specific seat.
  # Returns a list (not a single value) since a batch can contain
  # multiple mulligan offers.
  #
  # Hand card extraction: the accompanying GameStateMessage contains
  # zones (ZoneType_Hand) with objectInstanceIds and gameObjects with
  # grpId (arena_id). We map instance IDs → arena_ids for the player's
  # seat to capture the actual opening hand.
  defp build_mulligan_offered(messages, match_id, occurred_at, match_context) do
    game_state = extract_game_state_for_mulligans(messages)
    cached_objects = match_context[:game_objects] || %{}
    game_number = match_context[:current_game_number]

    messages
    |> Enum.filter(&(&1["type"] == "GREMessageType_MulliganReq"))
    |> Enum.map(fn message ->
      seat_id = message["systemSeatIds"] |> List.first()

      hand_size =
        get_in(message, ["prompt", "parameters"])
        |> List.wrap()
        |> Enum.find_value(fn
          %{"parameterName" => "NumberOfCards", "numberValue" => n} -> n
          _ -> nil
        end)

      hand_arena_ids = extract_hand_arena_ids(game_state, seat_id, cached_objects)

      %MulliganOffered{
        mtga_match_id: match_id,
        game_number: game_number,
        seat_id: seat_id,
        hand_size: hand_size || 7,
        hand_arena_ids: hand_arena_ids,
        occurred_at: occurred_at
      }
    end)
  end

  defp extract_game_state_for_mulligans(messages) do
    messages
    |> Enum.find_value(fn msg ->
      if Helpers.game_state_message?(msg), do: Helpers.extract_game_state(msg)
    end)
  end

  defp extract_hand_arena_ids(nil, _seat_id, _cached_hand), do: nil

  defp extract_hand_arena_ids(game_state, seat_id, cached_hand) do
    zones = game_state["zones"] || []
    game_objects = game_state["gameObjects"] || []

    # Try to resolve from this message's own data first.
    instance_to_grp =
      case game_objects do
        [] -> %{}
        objs -> Map.new(objs, fn obj -> {obj["instanceId"], obj["grpId"]} end)
      end

    hand_instance_ids =
      Enum.find_value(zones, fn
        %{"type" => "ZoneType_Hand", "ownerSeatId" => ^seat_id, "objectInstanceIds" => ids} ->
          ids

        _ ->
          nil
      end)

    case {hand_instance_ids, instance_to_grp} do
      {ids, mapping} when is_list(ids) and map_size(mapping) > 0 ->
        resolved = Enum.map(ids, &Map.get(mapping, &1)) |> Enum.reject(&is_nil/1)
        if resolved != [], do: resolved, else: use_cached_hand(cached_hand, hand_instance_ids)

      {ids, _} when is_list(ids) ->
        # No gameObjects in this message — fall back to accumulated game_objects map.
        use_cached_hand(cached_hand, hand_instance_ids)

      _ ->
        nil
    end
  end

  # Resolve hand instance IDs against the accumulated game_objects map.
  defp use_cached_hand(game_objects, hand_instance_ids)
       when is_map(game_objects) and is_list(hand_instance_ids) do
    resolved = Enum.map(hand_instance_ids, &Map.get(game_objects, &1)) |> Enum.reject(&is_nil/1)
    if resolved != [], do: resolved, else: nil
  end

  defp use_cached_hand(_, _), do: nil

  # ── Turn structure events from turnInfo ───────────────────────────
  #
  # Emits TurnStarted when turnNumber changes and PhaseChanged when phase
  # changes. Delta detection is done against match_context[:turn_phase_state].
  # Only the first GameStateMessage in a batch that carries new turnInfo is
  # checked — we emit at most one TurnStarted and one PhaseChanged per batch.

  defp build_turn_structure_events(messages, match_id, occurred_at, match_context) do
    game_number = match_context[:current_game_number]
    prev = match_context[:turn_phase_state] || %{}

    # Find the first GameStateMessage that carries a turnInfo map.
    turn_info =
      Enum.find_value(messages, fn msg ->
        if Helpers.game_state_message?(msg) do
          gsm = Helpers.extract_game_state(msg)
          info = gsm["turnInfo"] || %{}
          if map_size(info) > 0, do: info
        end
      end)

    if is_nil(turn_info) do
      []
    else
      current_turn = turn_info["turnNumber"]
      current_phase = turn_info["phase"]
      current_step = turn_info["step"]

      turn_event =
        if current_turn && current_turn != prev[:turn] do
          %TurnStarted{
            mtga_match_id: match_id,
            game_number: game_number,
            turn_number: current_turn,
            active_player_seat: turn_info["activePlayer"],
            occurred_at: occurred_at
          }
        end

      phase_event =
        if current_phase && current_phase != prev[:phase] do
          %PhaseChanged{
            mtga_match_id: match_id,
            game_number: game_number,
            turn_number: current_turn,
            phase: current_phase,
            step: current_step,
            occurred_at: occurred_at
          }
        end

      [turn_event, phase_event] |> Enum.reject(&is_nil/1)
    end
  end

  # ── PriorityAssigned from turnInfo ────────────────────────────────
  #
  # Emits PriorityAssigned for every GameStateMessage that carries a
  # priorityPlayer in turnInfo. No delta detection — every priority
  # assignment is a meaningful discrete fact.

  defp build_priority_assigned_events(messages, match_id, occurred_at, match_context) do
    game_number = match_context[:current_game_number]

    messages
    |> Enum.flat_map(fn msg ->
      if Helpers.game_state_message?(msg) do
        gsm = Helpers.extract_game_state(msg)
        turn_info = gsm["turnInfo"] || %{}
        priority_seat = turn_info["priorityPlayer"]

        if priority_seat do
          [
            %PriorityAssigned{
              mtga_match_id: match_id,
              game_number: game_number,
              turn_number: turn_info["turnNumber"],
              phase: turn_info["phase"],
              step: turn_info["step"],
              player_seat: priority_seat,
              occurred_at: occurred_at
            }
          ]
        else
          []
        end
      else
        []
      end
    end)
  end

  # ── Permanent state events from game object snapshots ────────────────
  #
  # Emits PermanentTapped, PermanentUntapped, and PermanentStatsChanged by
  # comparing each game object's current state against the prior state stored
  # in match_context[:game_object_states]. Called for every GameStateMessage
  # in the batch so delta detection fires on the first message that carries
  # a changed object.
  #
  # isTapped is only present (as true) when the object is tapped; absent
  # means untapped. power/toughness are nested %{"value" => N} on creatures
  # and absent on non-creatures.

  defp build_permanent_state_events(messages, match_id, occurred_at, match_context) do
    game_number = match_context[:current_game_number]
    prior_states = match_context[:game_object_states] || %{}
    arena_ids = match_context[:game_objects] || %{}

    messages
    |> Enum.flat_map(fn msg ->
      if Helpers.game_state_message?(msg) do
        gsm = Helpers.extract_game_state(msg)
        turn_info = gsm["turnInfo"] || %{}
        game_objects = gsm["gameObjects"] || []
        turn_number = turn_info["turnNumber"]
        phase = turn_info["phase"]

        Enum.flat_map(game_objects, fn obj ->
          instance_id = obj["instanceId"]
          prior = Map.get(prior_states, instance_id, %{})

          current_tapped = obj["isTapped"] == true
          current_power = get_in(obj, ["power", "value"])
          current_toughness = get_in(obj, ["toughness", "value"])
          arena_id = Map.get(arena_ids, instance_id)

          tap_events =
            cond do
              current_tapped == true and prior[:tapped] != true ->
                [
                  %PermanentTapped{
                    mtga_match_id: match_id,
                    game_number: game_number,
                    turn_number: turn_number,
                    phase: phase,
                    arena_id: arena_id,
                    instance_id: instance_id,
                    occurred_at: occurred_at
                  }
                ]

              current_tapped == false and prior[:tapped] == true ->
                [
                  %PermanentUntapped{
                    mtga_match_id: match_id,
                    game_number: game_number,
                    turn_number: turn_number,
                    phase: phase,
                    arena_id: arena_id,
                    instance_id: instance_id,
                    occurred_at: occurred_at
                  }
                ]

              true ->
                []
            end

          stats_events =
            if (current_power != nil or current_toughness != nil) and
                 (current_power != prior[:power] or current_toughness != prior[:toughness]) do
              [
                %PermanentStatsChanged{
                  mtga_match_id: match_id,
                  game_number: game_number,
                  turn_number: turn_number,
                  phase: phase,
                  arena_id: arena_id,
                  instance_id: instance_id,
                  power: current_power,
                  toughness: current_toughness,
                  occurred_at: occurred_at
                }
              ]
            else
              []
            end

          tap_events ++ stats_events
        end)
      else
        []
      end
    end)
  end

  # ── Turn actions from GameStateMessage annotations ─────────────────
  #
  # Extracts meaningful game actions from GameStateMessage annotations.
  # Each ZoneTransfer with a category, DamageDealt, or ModifiedLife
  # annotation becomes a specific gameplay domain event. Low-value annotations
  # (phase changes, ability bookkeeping) are ignored.

  defp build_turn_actions(messages, match_id, occurred_at, match_context) do
    cached_objects = match_context[:game_objects] || %{}
    game_number = match_context[:current_game_number]

    messages
    |> Enum.flat_map(fn msg ->
      if Helpers.game_state_message?(msg) do
        gsm = Helpers.extract_game_state(msg)
        turn_info = gsm["turnInfo"] || %{}
        annotations = gsm["annotations"] || []
        persistent_annotations = gsm["persistentAnnotations"] || []
        game_objects = gsm["gameObjects"] || []

        # Build instance → grpId map from this message's objects
        local_objects = Map.new(game_objects, fn obj -> {obj["instanceId"], obj["grpId"]} end)

        # Merge with cached objects for resolution
        objects = Map.merge(Helpers.cached_objects_to_map(cached_objects), local_objects)

        # Build zone_id → ownerSeatId map for draw attribution
        zone_owners = Map.new(gsm["zones"] || [], &{&1["id"], &1["ownerSeatId"]})
        self_seat_id = match_context[:self_seat_id]

        all_annotations = annotations ++ persistent_annotations

        all_annotations
        |> Enum.flat_map(
          &annotation_to_turn_actions(
            &1,
            turn_info,
            match_id,
            occurred_at,
            objects,
            game_number,
            zone_owners,
            self_seat_id
          )
        )
      else
        []
      end
    end)
  end

  defp annotation_to_turn_actions(
         %{"type" => ["AnnotationType_ZoneTransfer"]} = ann,
         turn_info,
         match_id,
         occurred_at,
         objects,
         game_number,
         zone_owners,
         self_seat_id
       ) do
    details = ann["details"] || []
    category = Helpers.find_detail_string(details, "category")
    instance_id = ann["affectedIds"] |> List.wrap() |> List.first()
    grp_id = Map.get(objects, instance_id)

    zone_from = Helpers.find_detail_int(details, "zone_src")
    zone_to = Helpers.find_detail_int(details, "zone_dest")

    common = %{
      mtga_match_id: match_id,
      game_number: game_number,
      turn_number: turn_info["turnNumber"],
      phase: turn_info["phase"],
      active_player: turn_info["activePlayer"],
      card_arena_id: grp_id,
      occurred_at: occurred_at
    }

    event =
      case category do
        "PlayLand" ->
          struct(LandPlayed, common)

        "CastSpell" ->
          struct(SpellCast, common)

        "Resolve" ->
          struct(SpellResolved, common)

        "Draw" ->
          drawer_seat_id = Map.get(zone_owners, zone_to)

          is_self_draw =
            if is_integer(drawer_seat_id) && is_integer(self_seat_id) do
              drawer_seat_id == self_seat_id
            end

          struct(CardDrawn, Map.put(common, :is_self_draw, is_self_draw))

        "Destroy" ->
          struct(PermanentDestroyed, common)

        "Sacrifice" ->
          struct(
            ZoneChanged,
            Map.merge(common, %{
              reason: "sacrifice",
              zone_from: Helpers.zone_name(zone_from),
              zone_to: Helpers.zone_name(zone_to)
            })
          )

        "Exile" ->
          struct(CardExiled, common)

        "Discard" ->
          struct(
            ZoneChanged,
            Map.merge(common, %{
              reason: "discard",
              zone_from: Helpers.zone_name(zone_from),
              zone_to: Helpers.zone_name(zone_to)
            })
          )

        "Return" ->
          struct(
            ZoneChanged,
            Map.merge(common, %{
              reason: "return",
              zone_from: Helpers.zone_name(zone_from),
              zone_to: Helpers.zone_name(zone_to)
            })
          )

        "SBA_Damage" ->
          struct(PermanentDestroyed, common)

        "SBA_Deathtouch" ->
          struct(PermanentDestroyed, common)

        "Put" ->
          struct(
            ZoneChanged,
            Map.merge(common, %{
              reason: "put",
              zone_from: Helpers.zone_name(zone_from),
              zone_to: Helpers.zone_name(zone_to)
            })
          )

        _ ->
          nil
      end

    if event, do: [event], else: []
  end

  defp annotation_to_turn_actions(
         %{"type" => ["AnnotationType_DamageDealt"]} = ann,
         turn_info,
         match_id,
         occurred_at,
         objects,
         game_number,
         _zone_owners,
         _self_seat_id
       ) do
    details = ann["details"] || []
    damage = Helpers.find_detail_int(details, "damage")
    source_id = ann["affectorId"]
    grp_id = Map.get(objects, source_id)

    [
      %CombatDamageDealt{
        mtga_match_id: match_id,
        game_number: game_number,
        turn_number: turn_info["turnNumber"],
        phase: turn_info["phase"],
        active_player: turn_info["activePlayer"],
        card_arena_id: grp_id,
        amount: damage,
        occurred_at: occurred_at
      }
    ]
  end

  defp annotation_to_turn_actions(
         %{"type" => ["AnnotationType_ModifiedLife"]} = ann,
         turn_info,
         match_id,
         occurred_at,
         _objects,
         game_number,
         _zone_owners,
         _self_seat_id
       ) do
    details = ann["details"] || []
    life_change = Helpers.find_detail_int(details, "life")
    affected_player = ann["affectedIds"] |> List.wrap() |> List.first()

    [
      %LifeTotalChanged{
        mtga_match_id: match_id,
        game_number: game_number,
        turn_number: turn_info["turnNumber"],
        phase: turn_info["phase"],
        active_player: turn_info["activePlayer"],
        amount: life_change,
        affected_player: affected_player,
        occurred_at: occurred_at
      }
    ]
  end

  defp annotation_to_turn_actions(
         %{"type" => ["AnnotationType_TokenCreated"]} = ann,
         turn_info,
         match_id,
         occurred_at,
         objects,
         game_number,
         _zone_owners,
         _self_seat_id
       ) do
    instance_id = ann["affectedIds"] |> List.wrap() |> List.first()
    grp_id = Map.get(objects, instance_id)

    [
      %TokenCreated{
        mtga_match_id: match_id,
        game_number: game_number,
        turn_number: turn_info["turnNumber"],
        phase: turn_info["phase"],
        active_player: turn_info["activePlayer"],
        card_arena_id: grp_id,
        occurred_at: occurred_at
      }
    ]
  end

  defp annotation_to_turn_actions(
         %{"type" => ["AnnotationType_CounterAdded"]} = ann,
         turn_info,
         match_id,
         occurred_at,
         objects,
         game_number,
         _zone_owners,
         _self_seat_id
       ) do
    details = ann["details"] || []
    instance_id = ann["affectedIds"] |> List.wrap() |> List.first()
    grp_id = Map.get(objects, instance_id)
    amount = Helpers.find_detail_int(details, "transaction_amount")

    [
      %CounterAdded{
        mtga_match_id: match_id,
        game_number: game_number,
        turn_number: turn_info["turnNumber"],
        phase: turn_info["phase"],
        active_player: turn_info["activePlayer"],
        card_arena_id: grp_id,
        amount: amount,
        occurred_at: occurred_at
      }
    ]
  end

  defp annotation_to_turn_actions(
         %{"type" => ["AnnotationType_TargetSpec"]} = ann,
         turn_info,
         match_id,
         occurred_at,
         objects,
         game_number,
         _zone_owners,
         _self_seat_id
       ) do
    spell_instance_id = ann["affectorId"]
    target_instance_ids = ann["affectedIds"] || []

    targets =
      Enum.map(target_instance_ids, fn instance_id ->
        %{instance_id: instance_id, arena_id: Map.get(objects, instance_id)}
      end)

    [
      %TargetsDeclared{
        mtga_match_id: match_id,
        game_number: game_number,
        turn_number: turn_info["turnNumber"],
        spell_instance_id: spell_instance_id,
        targets: targets,
        occurred_at: occurred_at
      }
    ]
  end

  defp annotation_to_turn_actions(
         %{"type" => ["AnnotationType_ActivatedAbility"]} = ann,
         turn_info,
         match_id,
         occurred_at,
         objects,
         game_number,
         _zone_owners,
         _self_seat_id
       ) do
    source_instance_id = ann["affectorId"]
    source_arena_id = Map.get(objects, source_instance_id)

    [
      %AbilityActivated{
        mtga_match_id: match_id,
        game_number: game_number,
        turn_number: turn_info["turnNumber"],
        phase: turn_info["phase"],
        source_instance_id: source_instance_id,
        source_arena_id: source_arena_id,
        occurred_at: occurred_at
      }
    ]
  end

  defp annotation_to_turn_actions(
         %{"type" => ["AnnotationType_TriggeredAbility"]} = ann,
         turn_info,
         match_id,
         occurred_at,
         objects,
         game_number,
         _zone_owners,
         _self_seat_id
       ) do
    details = ann["details"] || []
    source_instance_id = ann["affectorId"]
    source_arena_id = Map.get(objects, source_instance_id)
    trigger_type = Helpers.find_detail_string(details, "trigger_type")

    [
      %TriggerCreated{
        mtga_match_id: match_id,
        game_number: game_number,
        turn_number: turn_info["turnNumber"],
        phase: turn_info["phase"],
        source_instance_id: source_instance_id,
        source_arena_id: source_arena_id,
        trigger_type: trigger_type,
        occurred_at: occurred_at
      }
    ]
  end

  # All other annotation types — skip silently
  defp annotation_to_turn_actions(
         _ann,
         _turn_info,
         _match_id,
         _occurred_at,
         _objects,
         _game_number,
         _zone_owners,
         _self_seat_id
       ),
       do: []
end
