defmodule Scry2.MtgaLogIngestion.LocateLogFile do
  @moduledoc """
  Locates the MTGA `Player.log` file.

  Resolution order:

  1. Runtime override from `Scry2.Settings.get("mtga_logs_player_log_path")`
     — the setup tour writes the user's manually-entered path here so
     it takes effect immediately without a restart or TOML edit.

  2. Explicit override from `Scry2.Config.get(:mtga_logs_player_log_path)`
     (settable via TOML user config).

  3. Multi-path scan of well-known locations — returns the first that
     exists on disk.

  The default candidate list covers the common Linux/Proton/Wine/Bottles
  layouts plus native macOS. The Steam Proton flatpak path is listed
  first because it's the most common setup for Linux MTGA players
  (matches the user's existing `wine_untappedgg_companion` workflow).
  """

  @type result :: {:ok, String.t()} | {:error, :not_found}

  @doc """
  Resolves the `Player.log` path using override → multi-path scan.
  """
  @spec resolve() :: result()
  def resolve do
    case override() do
      path when is_binary(path) ->
        if File.regular?(path), do: {:ok, path}, else: {:error, :not_found}

      _ ->
        scan_candidates(default_candidates())
    end
  end

  @doc """
  Resolves using an explicit candidate list — useful for tests.
  """
  @spec resolve(override: String.t() | nil, candidates: [String.t()]) :: result()
  def resolve(opts) when is_list(opts) do
    case Keyword.get(opts, :override) do
      path when is_binary(path) ->
        if File.regular?(path), do: {:ok, path}, else: {:error, :not_found}

      _ ->
        scan_candidates(Keyword.fetch!(opts, :candidates))
    end
  end

  @doc """
  Returns the built-in candidate path list, with `~` expanded.
  Exposed for inspection / display in the settings LiveView.
  """
  @spec default_candidates() :: [String.t()]
  def default_candidates, do: Scry2.Platform.mtga_log_candidates()

  # Runtime override (Settings table) wins over static override (TOML via
  # Scry2.Config). The setup tour writes to Settings; users with a TOML
  # override still work because Config fallback is consulted when Settings
  # has nothing.
  defp override do
    Scry2.Settings.get_or_config("mtga_logs_player_log_path", :mtga_logs_player_log_path)
  end

  defp scan_candidates(candidates) do
    case Enum.find(candidates, &File.regular?/1) do
      nil -> {:error, :not_found}
      path -> {:ok, path}
    end
  end
end
