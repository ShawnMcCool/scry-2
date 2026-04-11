defmodule Scry2.Platform do
  @moduledoc """
  Single source of truth for all platform-specific filesystem paths.

  No other module calls `:os.type()` or references OS-specific directory
  conventions. Everything goes through here.

  All functions return paths constructed with `Path.join/1` — separators
  are correct for the running OS regardless of which platform the release
  was built on.
  """

  @mtga_appid "2141910"

  # ── Application paths ─────────────────────────────────────────────────────

  @doc """
  Path to the user's `config.toml`.

  | Platform | Path |
  |---|---|
  | Linux/macOS | `~/.config/scry_2/config.toml` |
  | Windows | `%APPDATA%\\scry_2\\config.toml` |
  """
  @spec config_path() :: String.t()
  def config_path do
    case :os.type() do
      {:win32, _} ->
        Path.join([System.get_env("APPDATA") || System.user_home!(), "scry_2", "config.toml"])

      _ ->
        Path.expand("~/.config/scry_2/config.toml")
    end
  end

  @doc """
  Platform-appropriate user data directory for application state (database, cache).

  | Platform | Path |
  |---|---|
  | Linux | `~/.local/share/scry_2` |
  | macOS | `~/Library/Application Support/scry_2` |
  | Windows | `%LOCALAPPDATA%\\scry_2` |
  """
  @spec data_dir() :: String.t()
  def data_dir do
    case :os.type() do
      {:win32, _} ->
        Path.join([System.get_env("LOCALAPPDATA") || System.user_home!(), "scry_2"])

      {:unix, :darwin} ->
        Path.join([System.user_home!(), "Library", "Application Support", "scry_2"])

      _ ->
        Path.expand("~/.local/share/scry_2")
    end
  end

  # ── MTGA paths ─────────────────────────────────────────────────────────────

  @doc """
  Ordered list of candidate paths for the MTGA `Player.log` file.

  Covers Steam/Proton (Flatpak and native), Lutris, Bottles, native Windows,
  and native macOS. Returns all paths unconditionally — callers decide which
  to probe for existence.
  """
  @spec mtga_log_candidates() :: [String.t()]
  def mtga_log_candidates do
    home = System.user_home!()

    [
      # Steam (Flatpak) + Proton — most common Linux setup
      Path.join([
        home,
        ".var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/compatdata",
        @mtga_appid,
        "pfx/drive_c/users/steamuser/AppData/LocalLow/Wizards Of The Coast/MTGA/Player.log"
      ]),

      # Steam (native install) + Proton
      Path.join([
        home,
        ".local/share/Steam/steamapps/compatdata",
        @mtga_appid,
        "pfx/drive_c/users/steamuser/AppData/LocalLow/Wizards Of The Coast/MTGA/Player.log"
      ]),

      # Lutris
      Path.join([
        home,
        "Games/magic-the-gathering-arena/drive_c/users",
        System.get_env("USER", "steamuser"),
        "AppData/LocalLow/Wizards Of The Coast/MTGA/Player.log"
      ]),

      # Bottles (Flatpak)
      Path.join([
        home,
        ".var/app/com.usebottles.bottles/data/bottles/bottles/MTG-Arena/drive_c/users",
        System.get_env("USER", "steamuser"),
        "AppData/LocalLow/Wizards Of The Coast/MTGA/Player.log"
      ]),

      # Windows (native MTGA client)
      Path.join([home, "AppData", "LocalLow", "Wizards Of The Coast", "MTGA", "Player.log"]),

      # macOS (native)
      Path.join([home, "Library/Logs/Wizards Of The Coast/MTGA/Player.log"])
    ]
  end

  @doc """
  Ordered list of candidate directories for the MTGA `Raw_CardDatabase_*.mtga` file.

  Returns all paths unconditionally — callers decide which to probe for existence.
  """
  @spec mtga_raw_dir_candidates() :: [String.t()]
  def mtga_raw_dir_candidates do
    case :os.type() do
      {:win32, _} ->
        [
          Path.join([
            "C:\\",
            "Program Files",
            "Wizards of the Coast",
            "MTGA",
            "MTGA_Data",
            "Downloads",
            "Raw"
          ])
        ]

      _ ->
        home = System.user_home!()

        [
          Path.join([
            home,
            ".local/share/Steam/steamapps/common/MTGA/MTGA_Data/Downloads/Raw"
          ]),
          Path.join([
            home,
            ".var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/common/MTGA/MTGA_Data/Downloads/Raw"
          ])
        ]
    end
  end
end
