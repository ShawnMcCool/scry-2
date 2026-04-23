defmodule Scry2.SelfUpdate.UpdaterTest do
  use Scry2.DataCase, async: false
  alias Scry2.SelfUpdate.Updater
  alias Scry2.SelfUpdate.Storage
  alias Scry2.SelfUpdate.UpdateChecker
  alias Scry2.Topics

  setup do
    UpdateChecker.clear_cache()
    Storage.clear_all!()

    lock_path =
      System.tmp_dir!() |> Path.join("updater_test_#{System.unique_integer([:positive])}.lock")

    on_exit(fn -> File.rm_rf!(lock_path) end)

    stage_root =
      System.tmp_dir!() |> Path.join("stage_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(stage_root) end)

    %{lock_path: lock_path, stage_root: stage_root}
  end

  defp start_updater(ctx, overrides \\ []) do
    test_pid = self()

    defaults = [
      name: :"updater_#{System.unique_integer([:positive])}",
      lock_path: ctx.lock_path,
      staging_root: ctx.stage_root,
      current_version_fn: fn -> "0.14.0" end,
      downloader: fn _args, _opts ->
        send(test_pid, :download_called)
        {:ok, %{archive_path: "/tmp/a.tar.gz", sha256: "abc"}}
      end,
      stager: fn _archive, _dest ->
        send(test_pid, :stage_called)
        {:ok, "/tmp/a/extracted"}
      end,
      handoff: fn _args, _opts ->
        send(test_pid, :handoff_called)
        :ok
      end,
      system_stop_fn: fn _code -> send(test_pid, :system_stop_called) end
    ]

    merged = Keyword.merge(defaults, overrides)
    start_supervised!({Updater, merged})
    merged[:name]
  end

  test "initial state is :idle", ctx do
    name = start_updater(ctx)
    assert %{phase: :idle} = Updater.status(name)
  end

  test "apply_pending/1 with no cached release returns :no_update_pending", ctx do
    name = start_updater(ctx)
    assert {:error, :no_update_pending} = Updater.apply_pending(name)
  end

  test "apply_pending/1 with up-to-date cached release returns :up_to_date", ctx do
    UpdateChecker.put_cache(%{
      tag: "v0.14.0",
      version: "0.14.0",
      published_at: nil,
      html_url: "",
      body: ""
    })

    name = start_updater(ctx)
    assert {:error, :up_to_date} = Updater.apply_pending(name)
  end

  test "apply_pending/1 runs pipeline and broadcasts progress", ctx do
    UpdateChecker.put_cache(%{
      tag: "v0.15.0",
      version: "0.15.0",
      published_at: nil,
      html_url: "",
      body: ""
    })

    Phoenix.PubSub.subscribe(Scry2.PubSub, Topics.updates_progress())

    name = start_updater(ctx)
    assert :ok = Updater.apply_pending(name)

    assert_receive {:phase, :preparing}, 500
    assert_receive {:phase, :downloading}, 500
    assert_receive :download_called, 500
    assert_receive {:phase, :extracting}, 500
    assert_receive :stage_called, 500
    assert_receive {:phase, :handing_off}, 500
    assert_receive :handoff_called, 500
    assert_receive :system_stop_called, 500
  end

  test "apply_pending/1 releases the apply lock on failure", ctx do
    UpdateChecker.put_cache(%{
      tag: "v0.15.0",
      version: "0.15.0",
      published_at: nil,
      html_url: "",
      body: ""
    })

    Phoenix.PubSub.subscribe(Scry2.PubSub, Topics.updates_progress())

    name =
      start_updater(ctx,
        downloader: fn _args, _opts -> {:error, :checksum_mismatch} end
      )

    assert :ok = Updater.apply_pending(name)
    assert_receive {:phase, :failed, :checksum_mismatch}, 1_000

    refute File.exists?(ctx.lock_path)
  end

  test "apply_pending/1 returns :already_running while a prior apply is in flight", ctx do
    UpdateChecker.put_cache(%{
      tag: "v0.15.0",
      version: "0.15.0",
      published_at: nil,
      html_url: "",
      body: ""
    })

    test_pid = self()

    name =
      start_updater(ctx,
        downloader: fn _args, _opts ->
          send(test_pid, :download_blocked)
          Process.sleep(200)
          {:ok, %{archive_path: "x", sha256: "y"}}
        end
      )

    assert :ok = Updater.apply_pending(name)
    assert_receive :download_blocked, 500
    assert {:error, :already_running} = Updater.apply_pending(name)
  end

  test "apply_pending/1 with cached release whose tag is invalid returns :invalid_tag", ctx do
    # An invalid tag should never reach the cache (UpdateChecker's parse
    # path validates first), but defense in depth: even if the cache is
    # poisoned we refuse to apply.
    UpdateChecker.put_cache(%{
      tag: "not-a-valid-tag",
      version: "0.15.0",
      published_at: nil,
      html_url: "",
      body: ""
    })

    name = start_updater(ctx)
    assert {:error, :invalid_tag} = Updater.apply_pending(name)
  end

  test "apply_pending/1 with ahead_of_release returns :ahead_of_release", ctx do
    # Local is newer than the cached release (e.g. running a dev build
    # against an older published tag).
    UpdateChecker.put_cache(%{
      tag: "v0.13.0",
      version: "0.13.0",
      published_at: nil,
      html_url: "",
      body: ""
    })

    name = start_updater(ctx, current_version_fn: fn -> "0.14.0" end)
    assert {:error, :ahead_of_release} = Updater.apply_pending(name)
  end

  test "stager failure broadcasts :failed and releases the apply lock", ctx do
    UpdateChecker.put_cache(%{
      tag: "v0.15.0",
      version: "0.15.0",
      published_at: nil,
      html_url: "",
      body: ""
    })

    Phoenix.PubSub.subscribe(Scry2.PubSub, Topics.updates_progress())

    name =
      start_updater(ctx,
        stager: fn _archive, _dest -> {:error, :path_traversal} end
      )

    assert :ok = Updater.apply_pending(name)
    assert_receive {:phase, :failed, :path_traversal}, 1_000
    refute File.exists?(ctx.lock_path)
  end

  test "handoff failure broadcasts :failed and releases the apply lock", ctx do
    UpdateChecker.put_cache(%{
      tag: "v0.15.0",
      version: "0.15.0",
      published_at: nil,
      html_url: "",
      body: ""
    })

    Phoenix.PubSub.subscribe(Scry2.PubSub, Topics.updates_progress())

    name =
      start_updater(ctx,
        handoff: fn _args, _opts -> {:error, :spawn_failed} end
      )

    assert :ok = Updater.apply_pending(name)
    assert_receive {:phase, :failed, :spawn_failed}, 1_000
    refute File.exists?(ctx.lock_path)
  end

  test "after a failure, a new apply_pending can start a fresh run", ctx do
    UpdateChecker.put_cache(%{
      tag: "v0.15.0",
      version: "0.15.0",
      published_at: nil,
      html_url: "",
      body: ""
    })

    Phoenix.PubSub.subscribe(Scry2.PubSub, Topics.updates_progress())

    name =
      start_updater(ctx,
        downloader: fn _args, _opts -> {:error, :checksum_mismatch} end
      )

    assert :ok = Updater.apply_pending(name)
    assert_receive {:phase, :failed, :checksum_mismatch}, 1_000

    # The state machine must accept a new apply after :failed (not stay
    # stuck in :already_running forever).
    assert :ok = Updater.apply_pending(name)
    assert_receive {:phase, :failed, :checksum_mismatch}, 1_000
  end
end
