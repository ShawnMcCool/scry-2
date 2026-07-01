defmodule Scry2.Events.RawPruneTest do
  @moduledoc """
  Stage 1b (ADR-042 / ADR-039): bounded raw retention execution.

  The prune deletes raw MTGA log events older than the retention window.
  It NEVER deletes domain events — the domain log is the precious layer
  (ADR-017); domain events derived from pruned raw simply become orphaned,
  which correctly trips the full-rebuild coverage seatbelt afterward.
  """
  use Scry2.DataCase

  alias Scry2.Events
  alias Scry2.MtgaLogIngestion
  alias Scry2.MtgaLogIngestion.EventRecord
  alias Scry2.TestFactory

  describe "MtgaLogIngestion.prune_before!/1" do
    test "deletes raw older than the cutoff and keeps the rest" do
      old =
        TestFactory.create_event_record(%{
          event_type: "GreToClientEvent",
          mtga_timestamp: ~U[2026-01-01 00:00:00Z]
        })

      recent =
        TestFactory.create_event_record(%{
          event_type: "GreToClientEvent",
          mtga_timestamp: ~U[2026-06-01 00:00:00Z]
        })

      assert MtgaLogIngestion.prune_before!(~U[2026-03-01 00:00:00Z]) == 1

      assert Repo.get(EventRecord, old.id) == nil
      assert Repo.get(EventRecord, recent.id).id == recent.id
    end

    test "the cutoff is exclusive — an event exactly at the cutoff is kept" do
      at =
        TestFactory.create_event_record(%{mtga_timestamp: ~U[2026-03-01 00:00:00Z]})

      assert MtgaLogIngestion.prune_before!(~U[2026-03-01 00:00:00Z]) == 0
      assert Repo.get(EventRecord, at.id).id == at.id
    end

    test "never deletes domain events, even when their raw source is pruned" do
      raw =
        TestFactory.create_event_record(%{
          event_type: "GreToClientEvent",
          mtga_timestamp: ~U[2026-01-01 00:00:00Z]
        })

      Events.append!(TestFactory.build_match_created(%{mtga_match_id: "keep-me"}), raw)

      assert MtgaLogIngestion.prune_before!(~U[2026-03-01 00:00:00Z]) == 1

      # The domain event survives — it is now orphaned (a coverage gap).
      assert Events.count_by_type()["match_created"] == 1
      assert Events.raw_coverage_gap() == 1
    end
  end

  describe "Events.prune_raw!/1" do
    test "no-ops when retention is disabled (nil), keeping everything" do
      TestFactory.create_event_record(%{mtga_timestamp: ~U[2020-01-01 00:00:00Z]})

      assert %{deleted: 0, cutoff: nil} =
               Events.prune_raw!(retention_days: nil, now: ~U[2026-06-01 00:00:00Z])

      assert MtgaLogIngestion.count_all() == 1
    end

    test "prunes raw older than the retention window" do
      TestFactory.create_event_record(%{mtga_timestamp: ~U[2026-01-01 00:00:00Z]})
      TestFactory.create_event_record(%{mtga_timestamp: ~U[2026-05-25 00:00:00Z]})

      # 90 days before 2026-06-01 is 2026-03-03.
      assert %{deleted: 1, cutoff: ~U[2026-03-03 00:00:00Z]} =
               Events.prune_raw!(retention_days: 90, now: ~U[2026-06-01 00:00:00Z])

      assert MtgaLogIngestion.count_all() == 1
    end
  end
end
