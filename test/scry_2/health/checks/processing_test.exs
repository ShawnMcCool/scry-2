defmodule Scry2.Health.Checks.ProcessingTest do
  use ExUnit.Case, async: true

  alias Scry2.Health.Check
  alias Scry2.Health.Checks.Processing

  describe "low_error_count/1" do
    test "ok when zero errors" do
      check = Processing.low_error_count(0)
      assert %Check{id: :low_error_count, status: :ok} = check
    end

    test "warning for a small but non-zero count" do
      check = Processing.low_error_count(3)
      assert %Check{status: :warning} = check
      assert check.summary =~ "3 raw events"
    end

    test "warning at the threshold" do
      check = Processing.low_error_count(10)
      assert %Check{status: :warning} = check
    end

    test "error at >= 100" do
      check = Processing.low_error_count(250)
      assert %Check{status: :error} = check
    end
  end

  describe "projectors_caught_up/1" do
    test "pending when there are no projectors" do
      check = Processing.projectors_caught_up([])
      assert %Check{status: :pending} = check
    end

    test "ok when every projector is caught up" do
      projectors = [
        %{name: "matches", watermark: 100, max_event_id: 100, caught_up: true},
        %{name: "drafts", watermark: 50, max_event_id: 50, caught_up: true}
      ]

      check = Processing.projectors_caught_up(projectors)
      assert %Check{status: :ok} = check
      assert check.summary =~ "2 projectors"
    end

    test "warning when one or more projectors lag" do
      projectors = [
        %{name: "matches", watermark: 90, max_event_id: 100, caught_up: false},
        %{name: "drafts", watermark: 50, max_event_id: 50, caught_up: true}
      ]

      check = Processing.projectors_caught_up(projectors)
      assert %Check{status: :warning} = check
      assert check.summary =~ "1 projectors behind"
      assert check.summary =~ "10 events lag"
      assert check.detail =~ "matches"
    end
  end

  describe "no_unrecognized_backlog/2" do
    setup do
      %{known: MapSet.new(~w(MatchCreated GameStart))}
    end

    test "ok when everything matches the known set", %{known: known} do
      events_by_type = %{"MatchCreated" => 100, "GameStart" => 50}
      check = Processing.no_unrecognized_backlog(events_by_type, known)
      assert %Check{status: :ok} = check
    end

    test "ok when small number of unknown events", %{known: known} do
      # Below the 10-event threshold
      events_by_type = %{"MatchCreated" => 100, "NewThing" => 3}
      check = Processing.no_unrecognized_backlog(events_by_type, known)
      assert %Check{status: :ok} = check
      assert check.summary =~ "1 unrecognized"
      assert check.summary =~ "3 events"
    end

    test "warning when lots of unknown events", %{known: known} do
      events_by_type = %{"MatchCreated" => 100, "NewThing" => 50, "AnotherThing" => 75}
      check = Processing.no_unrecognized_backlog(events_by_type, known)
      assert %Check{status: :warning} = check
      assert check.summary =~ "2 unrecognized"
      assert check.summary =~ "125"
    end
  end
end
