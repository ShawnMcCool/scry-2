defmodule Scry2Web.Components.RecentCardGrantsCardTest do
  use ExUnit.Case, async: true
  alias Scry2Web.Components.RecentCardGrantsCard

  describe "source_label/1" do
    test "maps known MTGA source codes to player-readable labels" do
      assert RecentCardGrantsCard.source_label("EventReward") == "Event prize"
      assert RecentCardGrantsCard.source_label("EventGrantCardPool") == "Draft pool grant"
      assert RecentCardGrantsCard.source_label("RedeemVoucher") == "Voucher"
      assert RecentCardGrantsCard.source_label("LoginGrant") == "Login bonus"
      assert RecentCardGrantsCard.source_label("EventPayEntry") == "Event entry refund"
    end

    test "maps the MemoryDiff sentinel to its memory-detected label" do
      assert RecentCardGrantsCard.source_label("MemoryDiff") == "Detected from collection"
    end

    test "nil source falls through to 'Unknown source'" do
      assert RecentCardGrantsCard.source_label(nil) == "Unknown source"
    end

    test "unknown CamelCase source is humanised" do
      assert RecentCardGrantsCard.source_label("BoosterOpened") == "Booster opened"
      assert RecentCardGrantsCard.source_label("PrizeWallReward") == "Prize wall reward"
    end
  end

  describe "format_grant_card/2" do
    test "renders the resolved card name when present" do
      cards = %{86745 => %{name: "Adopted Eel"}}
      row = %{"arena_id" => 86745, "set_code" => "WOE", "card_added" => true}
      assert RecentCardGrantsCard.format_grant_card(row, cards) == "Adopted Eel"
    end

    test "falls back to '#<arena_id>' when the card is unknown" do
      row = %{"arena_id" => 99_999, "set_code" => "WOE", "card_added" => true}
      assert RecentCardGrantsCard.format_grant_card(row, %{}) == "#99999"
    end

    test "annotates duplicates that contributed to vault progress" do
      cards = %{12_345 => %{name: "Llanowar Elves"}}
      row = %{"arena_id" => 12_345, "set_code" => "DSK", "vault_progress" => 1}
      assert RecentCardGrantsCard.format_grant_card(row, cards) == "Llanowar Elves (vault)"
    end

    test "atom-keyed rows work as well as string-keyed" do
      cards = %{12_345 => %{name: "Llanowar Elves"}}
      row = %{arena_id: 12_345, set_code: "DSK", vault_progress: 0}
      assert RecentCardGrantsCard.format_grant_card(row, cards) == "Llanowar Elves"
    end

    test "treats missing or zero vault_progress as not vaulted" do
      cards = %{12_345 => %{name: "Llanowar Elves"}}

      assert RecentCardGrantsCard.format_grant_card(
               %{"arena_id" => 12_345, "vault_progress" => 0},
               cards
             ) == "Llanowar Elves"

      assert RecentCardGrantsCard.format_grant_card(
               %{"arena_id" => 12_345},
               cards
             ) == "Llanowar Elves"
    end
  end
end
