defmodule Scry2.MtgaLogIngestion.WatcherTest do
  # Not async: Watcher is a named singleton by default. We override the
  # name per-test, but the Repo is process-global.
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

  describe "polling" do
    @event_join_line File.read!("test/fixtures/mtga_logs/event_join.log")

    setup do
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "scry_2-watcher-poll-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf(tmp_dir) end)

      {:ok, tmp_path: Path.join(tmp_dir, "Player.log")}
    end

    defp start_polling_watcher(tmp_path) do
      {:ok, pid} =
        Watcher.start_link(
          name: :"watcher_#{System.unique_integer([:positive])}",
          path: tmp_path,
          poll_interval: 100
        )

      pid
    end

    test "ingests appended bytes within the poll interval", %{tmp_path: tmp_path} do
      File.write!(tmp_path, "")
      Topics.subscribe(Topics.mtga_logs_status())
      Topics.subscribe(Topics.mtga_logs_events())

      pid = start_polling_watcher(tmp_path)
      assert_receive {:status, :running}, 1_000

      File.write!(tmp_path, @event_join_line <> "\n", [:append])

      assert_receive {:events_inserted, 1}, 2_000

      GenServer.stop(pid)
    end

    @tag capture_log: true
    test "broadcasts :path_missing when the tailed file disappears", %{tmp_path: tmp_path} do
      File.write!(tmp_path, "")
      Topics.subscribe(Topics.mtga_logs_status())

      pid = start_polling_watcher(tmp_path)
      assert_receive {:status, :running}, 1_000

      File.rm!(tmp_path)

      assert_receive {:status, :path_missing}, 2_000
      assert Watcher.status(pid).state == :path_missing

      GenServer.stop(pid)
    end

    @tag capture_log: true
    test "recovers to :running and ingests when the file reappears", %{tmp_path: tmp_path} do
      File.write!(tmp_path, "")
      Topics.subscribe(Topics.mtga_logs_status())
      Topics.subscribe(Topics.mtga_logs_events())

      pid = start_polling_watcher(tmp_path)
      assert_receive {:status, :running}, 1_000

      File.rm!(tmp_path)
      assert_receive {:status, :path_missing}, 2_000

      File.write!(tmp_path, @event_join_line <> "\n")

      assert_receive {:status, :running}, 2_000
      assert_receive {:events_inserted, 1}, 2_000

      GenServer.stop(pid)
    end

    @tag capture_log: true
    test "starts tailing once a missing log file appears", %{tmp_path: tmp_path} do
      Topics.subscribe(Topics.mtga_logs_status())
      Topics.subscribe(Topics.mtga_logs_events())

      pid = start_polling_watcher(tmp_path)
      assert_receive {:status, :path_not_found}, 1_000

      File.write!(tmp_path, @event_join_line <> "\n")

      assert_receive {:status, :running}, 2_000
      assert_receive {:events_inserted, 1}, 2_000

      GenServer.stop(pid)
    end
  end
end
