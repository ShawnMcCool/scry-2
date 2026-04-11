defmodule Scry2Web.SettingsLive.FormTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Scry2Web.SettingsLive.Form

  describe "validate_player_log_path/1" do
    test "ok when the file exists", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "Player.log")
      File.write!(path, "")

      assert {:ok, ^path} = Form.validate_player_log_path(path)
    end

    test "expands ~ and relative paths", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "Player.log")
      File.write!(path, "")

      # Relative path from tmp_dir's parent
      assert {:ok, expanded} = Form.validate_player_log_path(path)
      assert expanded == Path.expand(path)
    end

    test "error when the file does not exist", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "missing.log")

      assert {:error, :not_a_file} = Form.validate_player_log_path(path)
    end

    test "error when the path points at a directory", %{tmp_dir: tmp_dir} do
      assert {:error, :not_a_file} = Form.validate_player_log_path(tmp_dir)
    end

    test "error when the path is blank" do
      assert {:error, :blank} = Form.validate_player_log_path("")
      assert {:error, :blank} = Form.validate_player_log_path("   ")
    end
  end

  describe "validate_data_dir/1" do
    test "ok when the directory exists", %{tmp_dir: tmp_dir} do
      assert {:ok, expanded} = Form.validate_data_dir(tmp_dir)
      assert expanded == Path.expand(tmp_dir)
    end

    test "error when the directory does not exist", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "nope")

      assert {:error, :not_a_directory} = Form.validate_data_dir(path)
    end

    test "error when the path points at a regular file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "file.txt")
      File.write!(path, "")

      assert {:error, :not_a_directory} = Form.validate_data_dir(path)
    end

    test "error when blank" do
      assert {:error, :blank} = Form.validate_data_dir("")
      assert {:error, :blank} = Form.validate_data_dir("   ")
    end
  end

  describe "validate_refresh_cron/1" do
    test "ok on a valid cron expression" do
      assert {:ok, "0 4 * * *"} = Form.validate_refresh_cron("0 4 * * *")
    end

    test "ok on shorthand expressions" do
      assert {:ok, "@daily"} = Form.validate_refresh_cron("@daily")
    end

    test "trims surrounding whitespace" do
      assert {:ok, "0 4 * * *"} = Form.validate_refresh_cron("  0 4 * * *  ")
    end

    test "error on invalid expression" do
      assert {:error, _reason} = Form.validate_refresh_cron("not a cron")
    end

    test "error when blank" do
      assert {:error, :blank} = Form.validate_refresh_cron("")
      assert {:error, :blank} = Form.validate_refresh_cron("  ")
    end
  end

  describe "validate_poll_interval_ms/1" do
    test "ok on integers in range" do
      assert {:ok, 500} = Form.validate_poll_interval_ms(500)
      assert {:ok, 100} = Form.validate_poll_interval_ms(100)
      assert {:ok, 10_000} = Form.validate_poll_interval_ms(10_000)
    end

    test "ok on binary integers in range" do
      assert {:ok, 750} = Form.validate_poll_interval_ms("750")
      assert {:ok, 750} = Form.validate_poll_interval_ms("  750  ")
    end

    test "error below the minimum" do
      assert {:error, :too_small} = Form.validate_poll_interval_ms(99)
      assert {:error, :too_small} = Form.validate_poll_interval_ms("50")
    end

    test "error above the maximum" do
      assert {:error, :too_large} = Form.validate_poll_interval_ms(10_001)
      assert {:error, :too_large} = Form.validate_poll_interval_ms("20000")
    end

    test "error on non-integer input" do
      assert {:error, :not_an_integer} = Form.validate_poll_interval_ms("abc")
      assert {:error, :not_an_integer} = Form.validate_poll_interval_ms("500ms")
    end

    test "error when blank" do
      assert {:error, :blank} = Form.validate_poll_interval_ms("")
      assert {:error, :blank} = Form.validate_poll_interval_ms("  ")
    end
  end

  describe "error_message/2" do
    test "player_log_path errors are human-readable" do
      assert Form.error_message(:player_log_path, :blank) =~ "cannot be blank"
      assert Form.error_message(:player_log_path, :not_a_file) =~ "No file exists"
    end

    test "data_dir errors are human-readable" do
      assert Form.error_message(:data_dir, :blank) =~ "cannot be blank"
      assert Form.error_message(:data_dir, :not_a_directory) =~ "No directory"
    end

    test "refresh_cron errors include the reason" do
      assert Form.error_message(:refresh_cron, :blank) =~ "cannot be blank"
      assert Form.error_message(:refresh_cron, "some reason") =~ "some reason"
    end
  end
end
