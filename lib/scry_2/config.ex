defmodule Scry2.Config do
  @moduledoc """
  Loads and serves application configuration from the user's
  TOML config file, falling back to application environment defaults.

  Call `load!/0` once at startup (before the supervision tree).
  Use `get/1` anywhere to read a config value from `:persistent_term`.

  On first run, if no config file exists, `load!/0` generates a minimal
  bootstrap config with a random `secret_key_base` and platform-appropriate
  data paths, then writes it to the config path before loading.

  Config file locations:
  - Linux/macOS: `~/.config/scry_2/config.toml`
  - Windows:     `%APPDATA%\\scry_2\\config.toml`
  """

  @type key ::
          :database_path
          | :cache_dir
          | :mtga_logs_player_log_path
          | :mtga_logs_poll_interval_ms
          | :mtga_data_dir
          | :cards_lands17_url
          | :cards_refresh_cron
          | :cards_scryfall_bulk_url
          | :image_cache_dir
          | :start_watcher
          | :start_importer

  @doc """
  Loads configuration from TOML and stores it in `:persistent_term`.
  Generates a bootstrap config.toml on first run if none exists.
  Must be called once before any `get/1` calls — at the top of
  `Application.start/2`, before the children list.
  """
  @spec load!() :: :ok
  def load! do
    unless Application.get_env(:scry_2, :skip_user_config, false) do
      init_if_needed!()
    end

    :persistent_term.put({__MODULE__, :config}, load_config())
    :ok
  end

  @spec get(key()) :: term()
  def get(key) do
    :persistent_term.get({__MODULE__, :config}) |> Map.get(key)
  end

  # ── First-run init ───────────────────────────────────────────────────────

  defp init_if_needed! do
    path = config_path()

    unless File.exists?(path) do
      File.mkdir_p!(Path.dirname(path))
      secret_key_base = Base.encode64(:crypto.strong_rand_bytes(64))
      data_dir = platform_data_dir()

      contents = """
      # Scry2 bootstrap configuration — generated on first run.
      # To customize settings, use the in-app Settings page.
      # For all available options, see:
      # https://github.com/shawnmccool/scry_2/blob/main/defaults/scry_2.toml

      secret_key_base = "#{secret_key_base}"

      [database]
      path = '#{Path.join(data_dir, "scry_2.db")}'

      [cache]
      dir = '#{Path.join(data_dir, "cache")}'
      """

      File.write!(path, contents)
    end
  end

  # ── Platform helpers ─────────────────────────────────────────────────────

  @doc """
  Returns the platform-appropriate path to the user's config.toml.

  Delegates to `Scry2.Platform.config_path/0`, with an optional
  `:config_path_override` application env for tests.
  """
  @spec config_path() :: String.t()
  def config_path do
    Application.get_env(:scry_2, :config_path_override) || Scry2.Platform.config_path()
  end

  defp platform_data_dir, do: Scry2.Platform.data_dir()

  # ── Config loading ───────────────────────────────────────────────────────

  defp load_config do
    data_dir = platform_data_dir()

    defaults = %{
      database_path:
        Path.expand(
          get_in(Application.get_env(:scry_2, Scry2.Repo), [:database]) ||
            Path.join(data_dir, "scry_2.db")
        ),
      cache_dir: Path.join(data_dir, "cache"),
      mtga_logs_player_log_path: nil,
      mtga_logs_poll_interval_ms: 500,
      cards_lands17_url: "https://17lands-public.s3.amazonaws.com/analysis_data/cards/cards.csv",
      cards_refresh_cron: "0 4 * * *",
      cards_scryfall_bulk_url: "https://api.scryfall.com/bulk-data/default-cards",
      image_cache_dir: Path.join(data_dir, "cache/images"),
      start_watcher: Application.get_env(:scry_2, :start_watcher, true),
      start_importer: Application.get_env(:scry_2, :start_importer, true),
      mtga_data_dir: nil
    }

    if Application.get_env(:scry_2, :skip_user_config, false) do
      defaults
    else
      load_toml(defaults)
    end
  end

  defp load_toml(defaults) do
    path = config_path()

    case File.read(path) do
      {:ok, contents} ->
        case Toml.decode(contents) do
          {:ok, toml} -> merge_toml(defaults, toml)
          {:error, _} -> defaults
        end

      {:error, _} ->
        defaults
    end
  end

  defp merge_toml(defaults, toml) do
    cache_dir =
      expand(get_in(toml, ["cache", "dir"])) ||
        defaults.cache_dir

    %{
      database_path: expand(get_in(toml, ["database", "path"])) || defaults.database_path,
      cache_dir: cache_dir,
      mtga_logs_player_log_path:
        expand(get_in(toml, ["mtga_logs", "player_log_path"])) ||
          defaults.mtga_logs_player_log_path,
      mtga_logs_poll_interval_ms:
        get_in(toml, ["mtga_logs", "poll_interval_ms"]) ||
          defaults.mtga_logs_poll_interval_ms,
      cards_lands17_url: get_in(toml, ["cards", "lands17_url"]) || defaults.cards_lands17_url,
      cards_refresh_cron: get_in(toml, ["cards", "refresh_cron"]) || defaults.cards_refresh_cron,
      cards_scryfall_bulk_url:
        get_in(toml, ["cards", "scryfall_bulk_url"]) || defaults.cards_scryfall_bulk_url,
      image_cache_dir:
        expand(get_in(toml, ["images", "cache_dir"])) ||
          Path.join(cache_dir, "images/"),
      start_watcher:
        value_or_default(get_in(toml, ["workers", "start_watcher"]), defaults.start_watcher),
      start_importer:
        value_or_default(get_in(toml, ["workers", "start_importer"]), defaults.start_importer),
      mtga_data_dir:
        expand(get_in(toml, ["mtga_logs", "data_dir"])) ||
          defaults.mtga_data_dir
    }
  end

  defp expand(path) when is_binary(path), do: Path.expand(path)
  defp expand(_), do: nil

  defp value_or_default(nil, default), do: default
  defp value_or_default(value, _default), do: value
end
