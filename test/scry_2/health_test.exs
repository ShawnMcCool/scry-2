defmodule Scry2.HealthTest do
  use Scry2.DataCase, async: false

  alias Scry2.Health
  alias Scry2.Health.Check
  alias Scry2.Health.Report

  describe "run_all/0" do
    test "returns a %Report{} with every expected check id" do
      report = Health.run_all()

      assert %Report{checks: checks, overall: overall, generated_at: %DateTime{}} = report
      assert overall in [:ok, :warning, :error]

      ids = Enum.map(checks, & &1.id) |> MapSet.new()

      expected =
        MapSet.new([
          :player_log_locatable,
          :watcher_running,
          :structured_events_seen,
          :lands17_present,
          :lands17_fresh,
          :scryfall_present,
          :scryfall_fresh,
          :low_error_count,
          :projectors_caught_up,
          :no_unrecognized_backlog,
          :self_user_id_configured,
          :database_writable,
          :data_dirs_exist
        ])

      missing = MapSet.difference(expected, ids)
      assert MapSet.size(missing) == 0, "missing check ids: #{inspect(MapSet.to_list(missing))}"
    end

    test "every check has the required fields populated" do
      %Report{checks: checks} = Health.run_all()

      for check <- checks do
        assert %Check{
                 id: id,
                 category: category,
                 name: name,
                 status: status,
                 checked_at: %DateTime{}
               } = check

        assert is_atom(id)
        assert category in [:ingestion, :card_data, :processing, :config]
        assert is_binary(name)
        assert status in [:ok, :warning, :error, :pending]
      end
    end
  end

  describe "run_category/1" do
    test "returns only ingestion checks for :ingestion" do
      results = Health.run_category(:ingestion)

      assert is_list(results)
      assert Enum.all?(results, &match?(%Check{category: :ingestion}, &1))
    end

    test "returns only card_data checks for :card_data" do
      results = Health.run_category(:card_data)
      assert Enum.all?(results, &match?(%Check{category: :card_data}, &1))
    end
  end

  describe "setup_ready?/0" do
    test "is false on an empty database (no player log, no cards, no events)" do
      # In the test env :start_watcher is false and no config sets a path,
      # so LocateLogFile.resolve/0 is almost certainly :not_found here.
      refute Health.setup_ready?()
    end
  end

  describe "auto_fix/1" do
    test ":manual returns an error tuple" do
      assert {:error, :requires_human_action} = Health.auto_fix(:manual)
    end

    test "nil returns an error tuple" do
      assert {:error, :no_fix_available} = Health.auto_fix(nil)
    end
  end
end
