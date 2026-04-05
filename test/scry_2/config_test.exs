defmodule Scry2.ConfigTest do
  # Not async: load!/0 writes to :persistent_term (global state).
  use ExUnit.Case, async: false

  alias Scry2.Config

  setup do
    # Snapshot the existing config so we can restore it after each test.
    previous = :persistent_term.get({Config, :config}, :__missing__)

    on_exit(fn ->
      case previous do
        :__missing__ -> :persistent_term.erase({Config, :config})
        config -> :persistent_term.put({Config, :config}, config)
      end
    end)

    :ok
  end

  describe "load!/0 with user config skipped" do
    setup do
      # test.exs already sets skip_user_config: true; make it explicit for
      # this test's invariant.
      Application.put_env(:scry_2, :skip_user_config, true)
      :ok = Config.load!()
    end

    test "exposes the 17lands cards.csv url as a default" do
      assert Config.get(:cards_lands17_url) ==
               "https://17lands-public.s3.amazonaws.com/analysis_data/cards/cards.csv"
    end

    test "exposes the default cron expression for refresh" do
      assert Config.get(:cards_refresh_cron) == "0 4 * * *"
    end

    test "exposes the default MTGA poll interval" do
      assert Config.get(:mtga_logs_poll_interval_ms) == 500
    end

    test "player_log_path is nil when unset (triggers multi-path scan)" do
      assert Config.get(:mtga_logs_player_log_path) == nil
    end

    test "worker toggles read from Application env" do
      Application.put_env(:scry_2, :start_watcher, false)
      Application.put_env(:scry_2, :start_importer, true)
      :ok = Config.load!()

      assert Config.get(:start_watcher) == false
      assert Config.get(:start_importer) == true
    end

    test "database_path is expanded to an absolute path" do
      assert Config.get(:database_path) |> String.starts_with?("/")
    end
  end
end
