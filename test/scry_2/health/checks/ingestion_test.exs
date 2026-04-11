defmodule Scry2.Health.Checks.IngestionTest do
  use ExUnit.Case, async: true

  alias Scry2.Health.Check
  alias Scry2.Health.Checks.Ingestion

  describe "player_log_locatable/1" do
    test "ok when resolver returns a path" do
      check = Ingestion.player_log_locatable({:ok, "/home/user/Player.log"})

      assert %Check{
               id: :player_log_locatable,
               category: :ingestion,
               status: :ok,
               summary: "Found at /home/user/Player.log"
             } = check
    end

    test "error with manual fix hint when resolver returns :not_found" do
      check = Ingestion.player_log_locatable({:error, :not_found})

      assert %Check{
               id: :player_log_locatable,
               category: :ingestion,
               status: :error,
               fix: :manual
             } = check

      assert check.detail =~ "Detailed Logs"
    end
  end

  describe "watcher_running/1" do
    test "ok when state is :running" do
      status = %{state: :running, path: "/tmp/Player.log", offset: 12_345}
      check = Ingestion.watcher_running(status)

      assert %Check{status: :ok, fix: nil} = check
      assert check.summary =~ "/tmp/Player.log"
      assert check.summary =~ "12345"
    end

    test "pending when state is :starting" do
      check = Ingestion.watcher_running(%{state: :starting, path: nil, offset: 0})
      assert %Check{status: :pending} = check
    end

    test "error + reload fix when state is :path_not_found" do
      check = Ingestion.watcher_running(%{state: :path_not_found, path: nil, offset: 0})
      assert %Check{status: :error, fix: :reload_watcher} = check
    end

    test "error + reload fix when state is :path_missing" do
      check = Ingestion.watcher_running(%{state: :path_missing, path: nil, offset: 0})
      assert %Check{status: :error, fix: :reload_watcher} = check
    end

    test "error + reload fix when state is :not_running" do
      check = Ingestion.watcher_running(%{state: :not_running, path: nil, offset: 0})
      assert %Check{status: :error, fix: :reload_watcher} = check
    end

    test "warning for unknown states" do
      check = Ingestion.watcher_running(%{state: :something_weird, path: nil, offset: 0})
      assert %Check{status: :warning} = check
    end
  end

  describe "structured_events_seen/3" do
    setup do
      %{known: MapSet.new(~w(MatchCreated GameStart DeckSubmit))}
    end

    test "pending when there are no raw events yet", %{known: known} do
      check = Ingestion.structured_events_seen(0, %{}, known)

      assert %Check{
               id: :structured_events_seen,
               status: :pending
             } = check

      assert check.detail =~ "Detailed Logs"
    end

    test "error when many raw lines but zero are recognized", %{known: known} do
      events_by_type = %{"PlainTextNoise" => 50, "OtherNoise" => 100}
      check = Ingestion.structured_events_seen(150, events_by_type, known)

      assert %Check{status: :error, fix: :manual} = check
      assert check.detail =~ "Detailed Logs (Plugin Support) is OFF"
    end

    test "pending when total raw is below the threshold and none are recognized", %{known: known} do
      events_by_type = %{"PlainTextNoise" => 2}
      check = Ingestion.structured_events_seen(2, events_by_type, known)
      assert %Check{status: :pending} = check
    end

    test "warning when recognized is well below half of raw", %{known: known} do
      events_by_type = %{"MatchCreated" => 1, "Noise" => 100}
      check = Ingestion.structured_events_seen(101, events_by_type, known)
      assert %Check{status: :warning} = check
    end

    test "ok when recognized events dominate", %{known: known} do
      events_by_type = %{"MatchCreated" => 50, "GameStart" => 40, "Weird" => 2}
      check = Ingestion.structured_events_seen(92, events_by_type, known)
      assert %Check{status: :ok} = check
      assert check.summary =~ "90"
    end
  end
end
