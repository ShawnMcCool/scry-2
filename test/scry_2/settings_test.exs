defmodule Scry2.SettingsTest do
  use Scry2.DataCase, async: true

  alias Scry2.Settings

  describe "get_or_config/2" do
    test "returns the Settings value when present" do
      Settings.put!("mtga_logs_player_log_path", "/from/settings.log")

      assert Settings.get_or_config(
               "mtga_logs_player_log_path",
               :mtga_logs_player_log_path
             ) == "/from/settings.log"
    end

    test "falls back to Config when Settings is absent" do
      # No Settings row; Config default for this key is nil, so set a
      # fake override via Application env is not straightforward. Instead
      # use a key that Config.get returns a non-nil value for.
      refute Settings.get("cards_refresh_cron")

      assert Settings.get_or_config("cards_refresh_cron", :cards_refresh_cron) ==
               Scry2.Config.get(:cards_refresh_cron)
    end

    test "returns nil when both Settings and Config are absent" do
      refute Settings.get("mtga_logs_player_log_path")
      assert Scry2.Config.get(:mtga_logs_player_log_path) == nil

      assert Settings.get_or_config(
               "mtga_logs_player_log_path",
               :mtga_logs_player_log_path
             ) == nil
    end
  end
end
