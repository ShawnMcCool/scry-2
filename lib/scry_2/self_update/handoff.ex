defmodule Scry2.SelfUpdate.Handoff do
  @moduledoc """
  Spawns the platform installer as a detached process that outlives the
  BEAM. After handoff the caller is expected to call `System.stop/1`; the
  installer is responsible for replacing files, removing the apply lock,
  and relaunching the tray binary.

  ## Security posture

    * On Unix, the installer and log paths are passed as **positional**
      argv entries (`$1`, `$2`), never interpolated into the `sh -c`
      command string. A path containing `;`, `&&`, `$()`, quotes, or
      newlines is just a (nonsensical) argv value; it is never parsed
      as shell.
    * On Windows, paths flow through `cmd /c start "" /B "<path>"`. We
      always control the path (`Platform.data_dir() ++ install.bat` or
      the bootstrapper basename validated against the archive), so the
      attack surface is internal. The double-quoted `start ""` builtin
      treats the title arg as the first quoted token, so a stray `"` in
      the path is the only way to break framing — and our path source
      never produces that.

  ## Testability

  Both `:os_type` and `:spawner` can be injected via options, so the
  module is covered by pure argv/env assertions without ever spawning a
  real process.
  """

  @type args :: %{
          required(:staged_root) => Path.t(),
          required(:archive_filename) => String.t()
        }

  @type spawner :: (String.t(), [String.t()], [{String.t(), String.t()}] -> :ok)

  @minimal_unix_env_keys ~w(HOME XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS XDG_DATA_DIRS XDG_CONFIG_DIRS)
  @minimal_windows_env_keys ~w(APPDATA LOCALAPPDATA USERPROFILE SystemRoot Path)

  # Linux script body — runs the installer in the background and returns
  # immediately. `setsid` (in the spawned argv) detaches from the BEAM's
  # session so SIGHUP cannot reach the child. `exec >>"$2" 2>&1` redirects
  # this shell's own stdio to the handoff log before any other command,
  # so every trace line plus the installer's output lands in the log.
  @linux_script ~S"""
  exec >>"$2" 2>&1
  printf 'handoff: started at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'handoff: launching %s\n' "$1"
  "$1" </dev/null &
  """

  # macOS uses `nohup` because `setsid` is not available on every
  # supported macOS version. `nohup` ignores SIGHUP in the child; the
  # `&` puts it in background and the parent sh exits immediately.
  @macos_script ~S"""
  exec >>"$2" 2>&1
  printf 'handoff: started at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'handoff: launching %s\n' "$1"
  nohup "$1" </dev/null >/dev/null 2>&1 &
  """

  @spec spawn_detached(args(), keyword()) :: :ok | {:error, term()}
  def spawn_detached(args, opts \\ []) do
    os_type = Keyword.get(opts, :os_type, :os.type())
    spawner = Keyword.get(opts, :spawner, &default_spawn/3)

    do_spawn(os_type, args, spawner)
  end

  defp do_spawn({:unix, :linux}, %{staged_root: root}, spawner) do
    # `scripts/release` packages the platform-specific installer as
    # plain `install` (renamed from `scripts/install-linux`); the
    # Stager has already stripped the archive's single wrapper
    # directory, so `staged_root` points directly at the release root.
    installer = Path.join(root, "install")
    log = Path.join(root, "handoff.log")
    env = take_env(@minimal_unix_env_keys) ++ [{"PATH", "/usr/local/bin:/usr/bin:/bin"}]

    spawner.(
      "setsid",
      ["sh", "-c", @linux_script, "--", installer, log],
      env
    )
  end

  defp do_spawn({:unix, :darwin}, %{staged_root: root}, spawner) do
    installer = Path.join(root, "install")
    log = Path.join(root, "handoff.log")
    env = take_env(@minimal_unix_env_keys) ++ [{"PATH", "/usr/local/bin:/usr/bin:/bin"}]

    spawner.(
      "/bin/sh",
      ["-c", @macos_script, "--", installer, log],
      env
    )
  end

  defp do_spawn({:win32, _}, %{staged_root: root, archive_filename: archive}, spawner) do
    env = take_env(@minimal_windows_env_keys)

    cmd =
      cond do
        String.ends_with?(archive, ".zip") ->
          bat = Path.join(root, "install.bat")
          "start \"\" /B \"#{bat}\""

        String.ends_with?(archive, ".exe") or String.ends_with?(archive, ".msi") ->
          bootstrapper = Path.join(root, Path.basename(archive))
          "start \"\" /B \"#{bootstrapper}\" /quiet /norestart"

        true ->
          "exit 1"
      end

    spawner.("cmd.exe", ["/c", cmd], env)
  end

  defp default_spawn(cmd, args, env) do
    # Production spawn: detach via Port so the process survives BEAM exit.
    # We don't use System.cmd because it blocks until the child exits.
    executable = System.find_executable(cmd) || cmd

    _port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :nouse_stdio,
        :hide,
        args: args,
        env: Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
      ])

    :ok
  rescue
    error -> {:error, {:spawn_failed, error}}
  end

  defp take_env(keys) do
    for key <- keys, val = System.get_env(key), is_binary(val), do: {key, val}
  end
end
