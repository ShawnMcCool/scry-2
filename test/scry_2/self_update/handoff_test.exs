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

  test "linux handoff invokes setsid sh -c <staged>/install-linux" do
    spawn_fn = capture_spawner()

    :ok =
      Handoff.spawn_detached(
        %{staged_root: "/tmp/staged", archive_filename: "scry_2-v0.15.0-linux-x86_64.tar.gz"},
        os_type: {:unix, :linux},
        spawner: spawn_fn
      )

    assert_receive {:spawn, "setsid", ["sh", "-c", cmd], env}
    assert cmd =~ "/tmp/staged/install-linux"
    assert cmd =~ "handoff.log"
    assert Enum.any?(env, &match?({"PATH", _}, &1))
  end

  test "macos handoff uses nohup via /bin/sh" do
    spawn_fn = capture_spawner()

    :ok =
      Handoff.spawn_detached(
        %{staged_root: "/tmp/staged", archive_filename: "scry_2-v0.15.0-macos-x86_64.tar.gz"},
        os_type: {:unix, :darwin},
        spawner: spawn_fn
      )

    assert_receive {:spawn, "/bin/sh", ["-c", cmd], _env}
    assert cmd =~ "nohup"
    assert cmd =~ "/tmp/staged/install-macos"
  end

  test "windows zip handoff starts install.bat detached" do
    spawn_fn = capture_spawner()

    :ok =
      Handoff.spawn_detached(
        %{staged_root: "C:\\staged", archive_filename: "scry_2-v0.15.0-windows-x86_64.zip"},
        os_type: {:win32, :nt},
        spawner: spawn_fn
      )

    assert_receive {:spawn, "cmd.exe", ["/c", cmd], _env}
    assert cmd =~ "install.bat"
    assert cmd =~ "C:\\staged"
  end

  test "windows msi handoff invokes the bootstrapper with /quiet /norestart" do
    spawn_fn = capture_spawner()

    :ok =
      Handoff.spawn_detached(
        %{staged_root: "C:\\staged", archive_filename: "Scry2Setup-0.15.0.exe"},
        os_type: {:win32, :nt},
        spawner: spawn_fn
      )

    assert_receive {:spawn, "cmd.exe", ["/c", cmd], _env}
    assert cmd =~ "Scry2Setup-0.15.0.exe"
    assert cmd =~ "/quiet"
    assert cmd =~ "/norestart"
  end
end
