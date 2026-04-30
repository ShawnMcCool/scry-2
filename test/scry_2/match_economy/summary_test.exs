defmodule Scry2.MatchEconomy.SummaryTest do
  use Scry2.DataCase, async: true
  alias Scry2.MatchEconomy.Summary

  describe "changeset" do
    test "accepts a complete row" do
      attrs = %{
        mtga_match_id: "match-123",
        started_at: DateTime.utc_now(),
        ended_at: DateTime.utc_now(),
        memory_gold_delta: 250,
        memory_gems_delta: 0,
        memory_wildcards_common_delta: 1,
        memory_wildcards_uncommon_delta: 0,
        memory_wildcards_rare_delta: 0,
        memory_wildcards_mythic_delta: 0,
        memory_vault_delta: 0.05,
        log_gold_delta: 250,
        log_gems_delta: 0,
        log_wildcards_common_delta: 1,
        log_wildcards_uncommon_delta: 0,
        log_wildcards_rare_delta: 0,
        log_wildcards_mythic_delta: 0,
        diff_gold: 0,
        diff_gems: 0,
        diff_wildcards_common: 0,
        diff_wildcards_uncommon: 0,
        diff_wildcards_rare: 0,
        diff_wildcards_mythic: 0,
        reconciliation_state: "complete"
      }

      cs = Summary.changeset(%Summary{}, attrs)
      assert cs.valid?
    end

    test "requires mtga_match_id and reconciliation_state" do
      cs = Summary.changeset(%Summary{}, %{})
      refute cs.valid?
      assert {:mtga_match_id, _} = List.keyfind(cs.errors, :mtga_match_id, 0)
      assert {:reconciliation_state, _} = List.keyfind(cs.errors, :reconciliation_state, 0)
    end

    test "rejects unknown reconciliation_state" do
      cs = Summary.changeset(%Summary{}, %{mtga_match_id: "x", reconciliation_state: "bogus"})
      refute cs.valid?
      assert {:reconciliation_state, _} = List.keyfind(cs.errors, :reconciliation_state, 0)
    end

    test "accepts incomplete state with all deltas nil" do
      attrs = %{mtga_match_id: "abc", reconciliation_state: "incomplete"}
      cs = Summary.changeset(%Summary{}, attrs)
      assert cs.valid?
    end
  end

  describe "unique constraint on mtga_match_id" do
    test "second insert with same id fails" do
      attrs = %{mtga_match_id: "dup-1", reconciliation_state: "incomplete"}
      assert {:ok, _} = %Summary{} |> Summary.changeset(attrs) |> Scry2.Repo.insert()

      assert {:error, cs} =
               %Summary{} |> Summary.changeset(attrs) |> Scry2.Repo.insert()

      assert {:mtga_match_id, _} = List.keyfind(cs.errors, :mtga_match_id, 0)
    end
  end
end
