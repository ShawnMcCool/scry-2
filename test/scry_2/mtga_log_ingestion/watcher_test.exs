defmodule Scry2.MtgaLogIngestion.WatcherTest do
  # Not async: Watcher is a named singleton by default. We override the
  # name per-test, but FileSystem and the Repo are process-global.
  use Scry2.DataCase, async: false

  alias Scry2.MtgaLogIngestion.Watcher
  alias Scry2.Topics

  describe "lifecycle with an unreachable path" do
    @tag capture_log: true
    test "enters :path_not_found gracefully without crashing" do
      Topics.subscribe(Topics.mtga_logs_status())

      {:ok, pid} =
        Watcher.start_link(
          name: :"watcher_#{System.unique_integer([:positive])}",
          path: "/nowhere/Player.log"
        )

      # Wait for the handle_continue bootstrap step to finish.
      assert_receive {:status, :path_not_found}, 1_000

      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end

  describe "lifecycle with a real tail file" do
    setup do
      tmp_path =
        Path.join(
          System.tmp_dir!(),
          "scry_2-watcher-test-#{System.unique_integer([:positive])}.log"
        )

      File.write!(tmp_path, "")
      on_exit(fn -> File.rm(tmp_path) end)

      {:ok, tmp_path: tmp_path}
    end

    test "starts and broadcasts :running status", %{tmp_path: tmp_path} do
      Topics.subscribe(Topics.mtga_logs_status())

      {:ok, pid} =
        Watcher.start_link(
          name: :"watcher_#{System.unique_integer([:positive])}",
          path: tmp_path
        )

      assert_receive {:status, :running}, 1_000

      status = Watcher.status(pid)
      assert status.state == :running
      assert status.path == tmp_path

      GenServer.stop(pid)
    end
  end
end
