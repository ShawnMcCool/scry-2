defmodule Scry2.SelfUpdate.Handoff do
  @moduledoc """
  Spawns the platform installer as a detached process that outlives the
  BEAM. After handoff the caller is expected to call `System.stop/1`; the
  installer is responsible for replacing files, removing the apply lock,
  and relaunching the tray binary.

  **Testability:** both `:os_type` and `:spawner` can be injected via
  options, so the module is covered by pure argv/env assertions without
  ever spawning a real process.
  """

  @type args :: %{
          required(:staged_root) => Path.t(),
          required(:archive_filename) => String.t()
        }

  @type spawner :: (String.t(), [String.t()], [{String.t(), String.t()}] -> :ok)

  @minimal_unix_env_keys ~w(HOME XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS XDG_DATA_DIRS XDG_CONFIG_DIRS)
  @minimal_windows_env_keys ~w(APPDATA LOCALAPPDATA USERPROFILE SystemRoot Path)

  @spec spawn_detached(args(), keyword()) :: :ok | {:error, term()}
  def spawn_detached(args, opts \\ []) do
    os_type = Keyword.get(opts, :os_type, :os.type())
    spawner = Keyword.get(opts, :spawner, &default_spawn/3)

    do_spawn(os_type, args, spawner)
  end

  defp do_spawn({:unix, :linux}, %{staged_root: root}, spawner) do
    script = Path.join(root, "install-linux")
    log = Path.join(root, "handoff.log")
    env = take_env(@minimal_unix_env_keys) ++ [{"PATH", "/usr/local/bin:/usr/bin:/bin"}]

    spawner.(
      "setsid",
      [
        "sh",
        "-c",
        "#{shell_quote(script)} >> #{shell_quote(log)} 2>&1 </dev/null &"
      ],
      env
    )
  end

  defp do_spawn({:unix, :darwin}, %{staged_root: root}, spawner) do
    script = Path.join(root, "install-macos")
    log = Path.join(root, "handoff.log")
    env = take_env(@minimal_unix_env_keys) ++ [{"PATH", "/usr/local/bin:/usr/bin:/bin"}]

    spawner.(
      "/bin/sh",
      [
        "-c",
        "nohup #{shell_quote(script)} >> #{shell_quote(log)} 2>&1 </dev/null &"
      ],
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

  defp shell_quote(path), do: ~s|'#{String.replace(path, "'", ~S|'\\''|)}'|
end
