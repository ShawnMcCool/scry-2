defmodule Scry2.Events.IdentifyDomainEvents.GameStateMessage do
  @moduledoc """
  Translator for GREMessageType_GameStateMessage messages within GreToClientEvent.

  Handles the bulk of in-game event extraction:
  - GameCompleted (MatchState_GameComplete)
  - DieRolled (DieRollResultsResp)
  - MulliganOffered (MulliganReq)
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

  @doc """
  Builds all GameStateMessage-derived domain events from a GRE message batch.

  Returns a flat list of domain events (may be empty).

  `player_seat` is resolved once per GRE batch by the caller.
  """
  def build(messages, match_id, occurred_at, player_seat, match_context) do
    [
      maybe_build_die_roll_completed(messages, match_id, occurred_at, player_seat),
      maybe_build_game_completed(messages, match_id, occurred_at, player_seat),
      build_mulligan_offered(messages, match_id, occurred_at, match_context),
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
  defp maybe_build_die_roll_completed(messages, match_id, occurred_at, player_seat)
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

  defp maybe_build_die_roll_completed(_messages, _match_id, _occurred_at, _player_seat), do: nil

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
        game_objects = gsm["gameObjects"] || []

        # Build instance → grpId map from this message's objects
        local_objects = Map.new(game_objects, fn obj -> {obj["instanceId"], obj["grpId"]} end)

        # Merge with cached objects for resolution
        objects = Map.merge(Helpers.cached_objects_to_map(cached_objects), local_objects)

        annotations
        |> Enum.flat_map(
          &annotation_to_turn_actions(&1, turn_info, match_id, occurred_at, objects, game_number)
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
         game_number
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
          struct(CardDrawn, common)

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
         _game_number
       ) do
    details = ann["details"] || []
    damage = Helpers.find_detail_int(details, "damage")
    source_id = ann["affectorId"]
    grp_id = Map.get(objects, source_id)

    [
      %CombatDamageDealt{
        mtga_match_id: match_id,
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
         _game_number
       ) do
    details = ann["details"] || []
    life_change = Helpers.find_detail_int(details, "life")
    affected_player = ann["affectedIds"] |> List.wrap() |> List.first()

    [
      %LifeTotalChanged{
        mtga_match_id: match_id,
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
         _game_number
       ) do
    instance_id = ann["affectedIds"] |> List.wrap() |> List.first()
    grp_id = Map.get(objects, instance_id)

    [
      %TokenCreated{
        mtga_match_id: match_id,
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
         _game_number
       ) do
    details = ann["details"] || []
    instance_id = ann["affectedIds"] |> List.wrap() |> List.first()
    grp_id = Map.get(objects, instance_id)
    amount = Helpers.find_detail_int(details, "transaction_amount")

    [
      %CounterAdded{
        mtga_match_id: match_id,
        turn_number: turn_info["turnNumber"],
        phase: turn_info["phase"],
        active_player: turn_info["activePlayer"],
        card_arena_id: grp_id,
        amount: amount,
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
         _game_number
       ),
       do: []
end
