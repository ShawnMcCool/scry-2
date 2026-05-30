defmodule Scry2.Events.RawCoverageGuardTest do
  @moduledoc """
  The seatbelt from ADR-039: destructive rebuild operations must refuse to
  delete the domain event log when surviving raw can no longer reproduce it.

  These tests exercise the guard against `retranslate_from_raw!/0` (the
  lightest wipe-then-rebuild path — it deletes domain events, re-marks raw
  unprocessed, and re-broadcasts, with no projector rebuild) and the pure
  coverage query `raw_coverage_gap/0`.
  """
  use Scry2.DataCase

  alias Scry2.Events
  alias Scry2.TestFactory

  describe "raw_coverage_gap/0" do
    test "is 0 when every domain event's source raw row still exists" do
      raw = TestFactory.create_event_record(%{event_type: "MatchGameRoomStateChangedEvent"})
      Events.append!(TestFactory.build_match_created(%{mtga_match_id: "cov-1"}), raw)

      assert Events.raw_coverage_gap() == 0
    end

    test "is 0 for synthetic domain events with nil source (not derived from raw)" do
      Events.append!(TestFactory.build_match_created(%{mtga_match_id: "cov-syn"}), nil)

      assert Events.raw_coverage_gap() == 0
    end

    test "counts domain events whose source raw row was pruned away" do
      raw = TestFactory.create_event_record(%{event_type: "GreToClientEvent"})
      Events.append!(TestFactory.build_match_created(%{mtga_match_id: "gap-1"}), raw)
      Events.append!(TestFactory.build_match_completed(%{mtga_match_id: "gap-1"}), raw)

      # Simulate retention pruning: the raw source is gone, its domain events remain.
      Scry2.Repo.delete!(raw)

      assert Events.raw_coverage_gap() == 2
    end
  end

  describe "retranslate_from_raw!/0 — coverage guard" do
    test "proceeds normally when raw fully covers the domain log" do
      raw = TestFactory.create_event_record(%{event_type: "MatchGameRoomStateChangedEvent"})
      Events.append!(TestFactory.build_match_created(%{mtga_match_id: "ok-1"}), raw)

      # No raise; wipes the domain log (rebuild happens via re-broadcast).
      assert :ok = Events.retranslate_from_raw!()
    end

    test "refuses and preserves the domain log when a coverage gap exists" do
      raw = TestFactory.create_event_record(%{event_type: "GreToClientEvent"})
      Events.append!(TestFactory.build_match_created(%{mtga_match_id: "refuse-1"}), raw)
      Scry2.Repo.delete!(raw)

      before = Events.max_event_id()
      assert before > 0

      assert_raise RuntimeError, ~r/refusing to retranslate/, fn ->
        Events.retranslate_from_raw!()
      end

      # The seatbelt's whole point: history is NOT deleted on refusal.
      assert Events.max_event_id() == before
      assert Events.count_by_type()["match_created"] == 1
    end

    test "force: true overrides the guard and proceeds despite a gap" do
      raw = TestFactory.create_event_record(%{event_type: "GreToClientEvent"})
      Events.append!(TestFactory.build_match_created(%{mtga_match_id: "force-1"}), raw)
      Scry2.Repo.delete!(raw)

      assert :ok = Events.retranslate_from_raw!(force: true)
      # Domain log was intentionally cleared (the orphaned event is gone).
      assert Events.count_by_type() == %{}
    end
  end

  describe "reset_all!/0 — coverage guard" do
    test "refuses and preserves the domain log when a coverage gap exists" do
      raw = TestFactory.create_event_record(%{event_type: "GreToClientEvent"})
      Events.append!(TestFactory.build_match_created(%{mtga_match_id: "reset-gap"}), raw)
      Scry2.Repo.delete!(raw)

      before = Events.max_event_id()

      assert_raise RuntimeError, ~r/refusing to retranslate/, fn ->
        Events.reset_all!()
      end

      assert Events.max_event_id() == before
    end
  end
end
