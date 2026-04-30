defmodule Scry2Web.Components.MatchEconomyCardTest do
  use ExUnit.Case, async: true
  alias Scry2.MatchEconomy.Summary
  alias Scry2Web.Components.MatchEconomyCard

  describe "currency_rows/1" do
    test "returns 7 rows in the expected order" do
      summary = %Summary{}
      rows = MatchEconomyCard.currency_rows(summary)
      assert length(rows) == 7
      labels = Enum.map(rows, & &1.label)

      assert labels == [
               "Gold",
               "Gems",
               "Common WC",
               "Uncommon WC",
               "Rare WC",
               "Mythic WC",
               "Vault"
             ]
    end

    test "Vault row has nil log and diff (memory-only)" do
      summary = %Summary{memory_vault_delta: 0.05}
      [_, _, _, _, _, _, vault] = MatchEconomyCard.currency_rows(summary)
      assert vault.memory == 0.05
      assert vault.log == nil
      assert vault.diff == nil
    end

    test "currency rows surface schema deltas" do
      summary = %Summary{
        memory_gold_delta: 250,
        log_gold_delta: 250,
        diff_gold: 0,
        memory_gems_delta: 0,
        memory_wildcards_common_delta: 1,
        log_wildcards_common_delta: 1,
        diff_wildcards_common: 0
      }

      rows = MatchEconomyCard.currency_rows(summary)
      gold_row = Enum.find(rows, &(&1.label == "Gold"))
      assert gold_row.memory == 250
      assert gold_row.log == 250
      assert gold_row.diff == 0

      common_row = Enum.find(rows, &(&1.label == "Common WC"))
      assert common_row.memory == 1
      assert common_row.diff == 0
    end
  end
end
