defmodule Scry2.Config do
  @moduledoc """
  Loads and serves application configuration from the user's
  TOML config file (`~/.config/scry_2/config.toml`), falling back
  to application environment defaults.

  Call `load!/0` once at startup (before the supervision tree).
  Use `get/1` anywhere to read a config value from `:persistent_term`.
  """

  @config_path "~/.config/scry_2/config.toml"

  @type key ::
          :database_path
          | :mtga_logs_player_log_path
          | :mtga_logs_poll_interval_ms
          | :mtga_self_user_id
          | :cards_lands17_url
          | :cards_refresh_cron
          | :start_watcher
          | :start_importer

  @doc """
  Loads configuration from TOML and stores it in `:persistent_term`.
  Must be called once before any `get/1` calls — typically at the
  top of `Application.start/2`, before the children list.
  """
  @spec load!() :: :ok
  def load! do
    :persistent_term.put({__MODULE__, :config}, load_config())
    :ok
  end

  @spec get(key()) :: term()
  def get(key) do
    :persistent_term.get({__MODULE__, :config}) |> Map.get(key)
  end

  defp load_config do
    defaults = %{
      database_path:
        Path.expand(
          get_in(Application.get_env(:scry_2, Scry2.Repo), [:database]) ||
            "~/.local/share/scry_2/scry_2.db"
        ),
      mtga_logs_player_log_path: nil,
      mtga_logs_poll_interval_ms: 500,
      mtga_self_user_id: nil,
      cards_lands17_url: "https://17lands-public.s3.amazonaws.com/analysis_data/cards/cards.csv",
      cards_refresh_cron: "0 4 * * *",
      start_watcher: Application.get_env(:scry_2, :start_watcher, true),
      start_importer: Application.get_env(:scry_2, :start_importer, true)
    }

    if Application.get_env(:scry_2, :skip_user_config, false) do
      defaults
    else
      load_toml(defaults)
    end
  end

  defp load_toml(defaults) do
    path = Path.expand(@config_path)

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
    %{
      database_path: expand(get_in(toml, ["database", "path"])) || defaults.database_path,
      mtga_logs_player_log_path:
        expand(get_in(toml, ["mtga_logs", "player_log_path"])) ||
          defaults.mtga_logs_player_log_path,
      mtga_logs_poll_interval_ms:
        get_in(toml, ["mtga_logs", "poll_interval_ms"]) ||
          defaults.mtga_logs_poll_interval_ms,
      mtga_self_user_id:
        get_in(toml, ["mtga_logs", "self_user_id"]) || defaults.mtga_self_user_id,
      cards_lands17_url: get_in(toml, ["cards", "lands17_url"]) || defaults.cards_lands17_url,
      cards_refresh_cron: get_in(toml, ["cards", "refresh_cron"]) || defaults.cards_refresh_cron,
      start_watcher:
        value_or_default(get_in(toml, ["workers", "start_watcher"]), defaults.start_watcher),
      start_importer:
        value_or_default(get_in(toml, ["workers", "start_importer"]), defaults.start_importer)
    }
  end

  defp expand(path) when is_binary(path), do: Path.expand(path)
  defp expand(_), do: nil

  defp value_or_default(nil, default), do: default
  defp value_or_default(value, _default), do: value
end
