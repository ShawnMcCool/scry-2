defmodule Scry2.Events.IdentifyDomainEvents.ConnectResp do
  @moduledoc """
  Translator for GREMessageType_ConnectResp messages within GreToClientEvent.

  ConnectResp carries the deck list submitted by the player at the start of
  a match. Produces a DeckSubmitted domain event.

  Called by the coordinator with pre-decoded `messages` (the inner
  `greToClientMessages` list), not a raw `EventRecord`. See
  `IdentifyDomainEvents` for the envelope decoding.
  """

  alias Scry2.Events.Deck.DeckSubmitted
  alias Scry2.Events.IdentifyDomainEvents.Helpers

  @doc """
  Builds a DeckSubmitted event from a GREMessageType_ConnectResp message in the batch,
  if present. Returns a list (empty or singleton).

  `player_seat` is resolved once per GRE batch by the caller.
  """
  def build(messages, match_id, occurred_at, player_seat, _match_context) do
    case Helpers.find_gre_message(messages, "GREMessageType_ConnectResp") do
      %{"connectResp" => connect_resp} ->
        deck_message = connect_resp["deckMessage"] || %{}
        seat_id = player_seat

        main_deck = Helpers.aggregate_card_list(deck_message["deckCards"] || [])
        sideboard = Helpers.aggregate_card_list(deck_message["sideboardCards"] || [])

        deck_id =
          if match_id, do: "#{match_id}:seat#{seat_id}", else: "pending:seat#{seat_id}"

        [
          %DeckSubmitted{
            mtga_match_id: match_id,
            mtga_deck_id: deck_id,
            main_deck: main_deck,
            sideboard: sideboard,
            self_seat_id: seat_id,
            occurred_at: occurred_at
          }
        ]

      _ ->
        []
    end
  end
end
