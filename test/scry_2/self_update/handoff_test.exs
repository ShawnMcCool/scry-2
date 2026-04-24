defmodule Scry2.SelfUpdate.HandoffTest do
  use ExUnit.Case, async: true
  alias Scry2.SelfUpdate.Handoff

  defp capture_spawner do
    test_pid = self()

    fn cmd, args, env ->
      send(test_pid, {:spawn, cmd, args, env})
      :ok
    end
  end

  describe "linux handoff" do
    test "spawns setsid sh -c <script> -- <installer> <log>" do
      :ok =
        Handoff.spawn_detached(
          %{staged_root: "/tmp/staged", archive_filename: "scry_2-v0.15.0-linux-x86_64.tar.gz"},
          os_type: {:unix, :linux},
          spawner: capture_spawner()
        )

      assert_receive {:spawn, "setsid", args, env}

      script_idx = Enum.find_index(args, &(&1 == "-c"))
      assert script_idx, "expected sh -c form"
      body = Enum.at(args, script_idx + 1)

      # Script body uses positional $1 / $2 only — paths must NOT be
      # interpolated into the shell-parsed script string.
      refute String.contains?(body, "/tmp/staged"),
             "script body must not interpolate the staged path"

      assert String.contains?(body, ~s("$1"))
      assert String.contains?(body, ~s("$2"))
      # Stdout/stderr redirected before any other command — guarantees a
      # log file even if the installer crashes immediately.
      assert String.contains?(body, ~s|exec >>"$2" 2>&1|)

      dashdash_idx = Enum.find_index(args, &(&1 == "--"))
      assert dashdash_idx > script_idx, "-- must come after the script body"
      assert Enum.at(args, dashdash_idx + 1) == "/tmp/staged/install-linux"
      assert Enum.at(args, dashdash_idx + 2) == "/tmp/staged/handoff.log"

      assert Enum.any?(env, &match?({"PATH", _}, &1))
    end
  end

  describe "macos handoff" do
    test "spawns /bin/sh -c <script> -- <installer> <log> with nohup" do
      :ok =
        Handoff.spawn_detached(
          %{staged_root: "/tmp/staged", archive_filename: "scry_2-v0.15.0-macos-aarch64.tar.gz"},
          os_type: {:unix, :darwin},
          spawner: capture_spawner()
        )

      assert_receive {:spawn, "/bin/sh", args, _env}

      script_idx = Enum.find_index(args, &(&1 == "-c"))
      body = Enum.at(args, script_idx + 1)

      # Same positional-argv invariant as Linux.
      refute String.contains?(body, "/tmp/staged"),
             "script body must not interpolate the staged path"

      assert String.contains?(body, "nohup")
      assert String.contains?(body, ~s("$1"))

      dashdash_idx = Enum.find_index(args, &(&1 == "--"))
      assert Enum.at(args, dashdash_idx + 1) == "/tmp/staged/install-macos"
      assert Enum.at(args, dashdash_idx + 2) == "/tmp/staged/handoff.log"
    end
  end

  describe "argv safety (regression)" do
    # Defense in depth — the staging path is always under our control,
    # but the shell-injection-via-path bug class disappears entirely
    # when paths flow as positional argv instead of script-string text.
    test "linux: shell metacharacters in the staged path stay as a single argv entry" do
      staged = "/tmp/evil;rm -rf $HOME/.bashrc#"

      :ok =
        Handoff.spawn_detached(
          %{staged_root: staged, archive_filename: "scry_2-v0.15.0-linux-x86_64.tar.gz"},
          os_type: {:unix, :linux},
          spawner: capture_spawner()
        )

      assert_receive {:spawn, "setsid", args, _env}
      dashdash_idx = Enum.find_index(args, &(&1 == "--"))
      installer = Enum.at(args, dashdash_idx + 1)

      assert installer == Path.join(staged, "install-linux")
      assert String.contains?(installer, ";")
      # And critically, the script body is unchanged — the metacharacters
      # are not in the shell-parsed text at all.
      script_idx = Enum.find_index(args, &(&1 == "-c"))
      body = Enum.at(args, script_idx + 1)
      refute String.contains?(body, "rm -rf")
    end

    test "macos: shell metacharacters in the staged path stay as a single argv entry" do
      staged = "/tmp/evil;rm -rf $HOME/.bashrc#"

      :ok =
        Handoff.spawn_detached(
          %{staged_root: staged, archive_filename: "scry_2-v0.15.0-macos-aarch64.tar.gz"},
          os_type: {:unix, :darwin},
          spawner: capture_spawner()
        )

      assert_receive {:spawn, "/bin/sh", args, _env}
      dashdash_idx = Enum.find_index(args, &(&1 == "--"))
      installer = Enum.at(args, dashdash_idx + 1)

      assert installer == Path.join(staged, "install-macos")
      script_idx = Enum.find_index(args, &(&1 == "-c"))
      body = Enum.at(args, script_idx + 1)
      refute String.contains?(body, "rm -rf")
    end
  end

  describe "diagnostic logging in the handoff script" do
    test "linux script writes trace lines so a stuck handoff can be diagnosed" do
      :ok =
        Handoff.spawn_detached(
          %{staged_root: "/tmp/staged", archive_filename: "scry_2-v0.15.0-linux-x86_64.tar.gz"},
          os_type: {:unix, :linux},
          spawner: capture_spawner()
        )

      assert_receive {:spawn, "setsid", args, _env}
      script_idx = Enum.find_index(args, &(&1 == "-c"))
      body = Enum.at(args, script_idx + 1)

      assert String.contains?(body, "handoff: started at")
      assert String.contains?(body, "handoff: launching")
    end
  end

  describe "windows zip handoff" do
    test "starts install.bat detached" do
      :ok =
        Handoff.spawn_detached(
          %{staged_root: "C:\\staged", archive_filename: "scry_2-v0.15.0-windows-x86_64.zip"},
          os_type: {:win32, :nt},
          spawner: capture_spawner()
        )

      assert_receive {:spawn, "cmd.exe", ["/c", cmd], _env}
      assert cmd =~ "install.bat"
      assert cmd =~ "C:\\staged"
    end
  end

  describe "windows msi handoff" do
    test "invokes the bootstrapper with /quiet /norestart" do
      :ok =
        Handoff.spawn_detached(
          %{staged_root: "C:\\staged", archive_filename: "Scry2Setup-0.15.0.exe"},
          os_type: {:win32, :nt},
          spawner: capture_spawner()
        )

      assert_receive {:spawn, "cmd.exe", ["/c", cmd], _env}
      assert cmd =~ "Scry2Setup-0.15.0.exe"
      assert cmd =~ "/quiet"
      assert cmd =~ "/norestart"
    end
  end
end
