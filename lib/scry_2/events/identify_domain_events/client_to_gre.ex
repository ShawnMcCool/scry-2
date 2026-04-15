defmodule Scry2.Events.IdentifyDomainEvents.ClientToGre do
  @moduledoc """
  Translator for ClientToGremessage events.

  ClientToGremessage carries the player's in-game actions. Most are
  high-volume UI responses (PerformActionResp, SelectTargetsResp) that
  we skip. We extract only high-signal decisions: concede, mulligan
  response, and play/draw choice.
  """

  alias Scry2.Events.Gameplay.{GameConceded, MulliganDecided, StartingPlayerChosen}
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

          _ ->
            nil
        end

      if event, do: {[event], []}, else: {[], []}
    else
      _ -> {[], []}
    end
  end
end
