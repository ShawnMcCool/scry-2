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

  # GUI session vars (DISPLAY / WAYLAND_DISPLAY / XAUTHORITY) are
  # required by the relaunched scry2-tray — without them GTK can't open
  # a display, the tray exits, and the watchdog never starts the BEAM.
  # The original whitelist stripped them along with RELEASE_*, breaking
  # every in-app update on Linux/macOS desktops.
  @minimal_unix_env_keys ~w(
    HOME
    XDG_RUNTIME_DIR
    DBUS_SESSION_BUS_ADDRESS
    XDG_DATA_DIRS
    XDG_CONFIG_DIRS
    DISPLAY
    WAYLAND_DISPLAY
    XAUTHORITY
  )
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
    env_fn = Keyword.get(opts, :env_fn, &System.get_env/1)

    do_spawn(os_type, args, spawner, env_fn)
  end

  defp do_spawn({:unix, :linux}, %{staged_root: root}, spawner, env_fn) do
    # `scripts/release` packages the platform-specific installer as
    # plain `install` (renamed from `scripts/install-linux`); the
    # Stager has already stripped the archive's single wrapper
    # directory, so `staged_root` points directly at the release root.
    installer = Path.join(root, "install")
    log = Path.join(root, "handoff.log")

    # `env -i` wipes the environment at exec time. Without it, every
    # variable the BEAM exports (including `RELEASE_VSN`,
    # `RELEASE_SYS_CONFIG`, etc., set by the running release's wrapper
    # script) leaks through `Port.open`'s inherit-and-add semantics
    # into the installer and the tray it relaunches. The tray then
    # spawns `bin/scry_2 start`, the wrapper sees the leaked
    # `RELEASE_VSN` pointing at the now-deleted previous-release
    # directory, and aborts in `set -e` before `exec erl` runs.
    spawner.(
      "setsid",
      ["env", "-i"] ++
        env_args(unix_env(env_fn)) ++
        ["sh", "-c", @linux_script, "--", installer, log],
      []
    )
  end

  defp do_spawn({:unix, :darwin}, %{staged_root: root}, spawner, env_fn) do
    installer = Path.join(root, "install")
    log = Path.join(root, "handoff.log")

    # See linux clause for the env-isolation rationale.
    spawner.(
      "/usr/bin/env",
      ["-i"] ++
        env_args(unix_env(env_fn)) ++
        ["/bin/sh", "-c", @macos_script, "--", installer, log],
      []
    )
  end

  defp do_spawn({:win32, _}, %{staged_root: root, archive_filename: archive}, spawner, env_fn) do
    env = take_env(@minimal_windows_env_keys, env_fn)

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

  defp take_env(keys, env_fn) do
    for key <- keys, val = env_fn.(key), is_binary(val), do: {key, val}
  end

  defp unix_env(env_fn) do
    take_env(@minimal_unix_env_keys, env_fn) ++ [{"PATH", "/usr/local/bin:/usr/bin:/bin"}]
  end

  defp env_args(env), do: Enum.map(env, fn {k, v} -> "#{k}=#{v}" end)
end
