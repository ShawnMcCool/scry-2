defmodule Scry2.Events.IdentifyDomainEvents.ClientToGre do
  @moduledoc """
  Translator for ClientToGremessage events.

  ClientToGremessage carries the player's in-game actions. We extract
  high-signal decisions from the following message types:

  | Message type | Domain event |
  |---|---|
  | `ClientMessageType_ConcedeReq` | `GameConceded` |
  | `ClientMessageType_MulliganResp` | `MulliganDecided` |
  | `ClientMessageType_ChooseStartingPlayerResp` | `StartingPlayerChosen` |
  | `ClientMessageType_PerformActionResp` (empty or all-pass actions) | `PriorityPassed` |

  `PerformActionResp` messages with `ActionType_Play` or `ActionType_Cast`
  actions are NOT priority passes — those actions are captured as
  `LandPlayed` / `SpellCast` events from GRE game state messages.
  """

  alias Scry2.Events.Gameplay.{GameConceded, MulliganDecided, StartingPlayerChosen}
  alias Scry2.Events.Priority.PriorityPassed
  alias Scry2.MtgaLogIngestion.EventRecord

  @doc """
  Translates a ClientToGremessage record into domain events.

  Returns `{[domain_events], [warnings]}`.
  """
  def translate(
        %EventRecord{event_type: "ClientToGremessage"} = record,
        _self_user_id,
        match_context
      ) do
    occurred_at = record.mtga_timestamp || record.inserted_at
    match_id = match_context[:current_match_id]

    with {:ok, payload} <- Jason.decode(record.raw_json),
         %{"type" => msg_type} = gre_payload <- payload["payload"] || payload do
      event =
        case msg_type do
          "ClientMessageType_ConcedeReq" ->
            scope = get_in(gre_payload, ["concedeReq", "scope"])

            %GameConceded{
              mtga_match_id: match_id,
              scope: scope,
              occurred_at: occurred_at
            }

          "ClientMessageType_MulliganResp" ->
            raw_decision = get_in(gre_payload, ["mulliganResp", "decision"])

            decision =
              case raw_decision do
                "MulliganOption_AcceptHand" -> "keep"
                "MulliganOption_Mulligan" -> "mulligan"
                other -> other
              end

            %MulliganDecided{
              mtga_match_id: match_id,
              decision: decision,
              occurred_at: occurred_at
            }

          "ClientMessageType_ChooseStartingPlayerResp" ->
            # The seat chosen to go first. Compare against the player's own
            # seat (from ConnectResp via ingestion state) to determine if the
            # player chose play (themselves) or draw (opponent).
            chosen_seat = get_in(gre_payload, ["chooseStartingPlayerResp", "systemSeatId"])
            self_seat_id = match_context[:self_seat_id]

            %StartingPlayerChosen{
              mtga_match_id: match_id,
              chose_play: chosen_seat == self_seat_id,
              occurred_at: occurred_at
            }

          "ClientMessageType_PerformActionResp" ->
            # Only emit PriorityPassed when the player passes priority without
            # taking an action: empty actions list, or all actions are
            # ActionType_Pass. Messages with ActionType_Play or ActionType_Cast
            # represent land plays and spell casts — not priority passes.
            perf = get_in(gre_payload, ["performActionResp"]) || %{}
            actions = perf["actions"] || []

            pure_pass =
              actions == [] or
                Enum.all?(actions, fn a -> a["actionType"] == "ActionType_Pass" end)

            if pure_pass do
              turn_phase = match_context[:turn_phase_state] || %{}

              %PriorityPassed{
                mtga_match_id: match_id,
                game_number: match_context[:current_game_number],
                turn_number: turn_phase[:turn],
                phase: turn_phase[:phase],
                step: turn_phase[:step],
                occurred_at: occurred_at
              }
            end

          _ ->
            nil
        end

      if event, do: {[event], []}, else: {[], []}
    else
      _ -> {[], []}
    end
  end
end
