defmodule Scry2Web.SettingsLive.Form do
  @moduledoc """
  Pure validators and helpers for `Scry2Web.SettingsLive` form fields.

  Per ADR-013, non-trivial LiveView logic lives in a helper module so
  it can be tested with `async: true` without mounting the LiveView.
  Each validator takes a raw string input and returns either
  `{:ok, normalised}` or `{:error, reason}`.

  `reason` is a structured value (atom or string). Use
  `error_message/2` to convert it into a user-facing string for
  display in the UI.
  """

  @doc """
  Validates an MTGA `Player.log` path. Expands `~`/relative segments
  and verifies the resulting path points at an existing regular file.
  """
  @spec validate_player_log_path(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def validate_player_log_path(raw) when is_binary(raw) do
    case String.trim(raw) do
      "" ->
        {:error, :blank}

      trimmed ->
        expanded = Path.expand(trimmed)
        if File.regular?(expanded), do: {:ok, expanded}, else: {:error, :not_a_file}
    end
  end

  @doc """
  Validates an MTGA data directory path (the `Raw/` folder that
  contains `Raw_CardDatabase_*.mtga`).
  """
  @spec validate_data_dir(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def validate_data_dir(raw) when is_binary(raw) do
    case String.trim(raw) do
      "" ->
        {:error, :blank}

      trimmed ->
        expanded = Path.expand(trimmed)
        if File.dir?(expanded), do: {:ok, expanded}, else: {:error, :not_a_directory}
    end
  end

  @doc """
  Validates a cron expression using Oban's own parser. The returned
  value is the trimmed expression string, ready to persist.

  Changes only take effect on the next boot — the Oban Cron plugin
  reads its `crontab:` option at supervisor start. The Settings UI
  should render a "restart required" notice alongside this field.
  """
  @spec validate_refresh_cron(String.t()) :: {:ok, String.t()} | {:error, atom() | String.t()}
  def validate_refresh_cron(raw) when is_binary(raw) do
    case String.trim(raw) do
      "" ->
        {:error, :blank}

      trimmed ->
        case Oban.Cron.Expression.parse(trimmed) do
          {:ok, _expr} -> {:ok, trimmed}
          {:error, %{message: msg}} -> {:error, msg}
        end
    end
  end

  @doc """
  Validates an integer `poll_interval_ms` value in the range
  100–10000. Accepts a trimmed binary or an integer.
  """
  @spec validate_poll_interval_ms(String.t() | integer()) ::
          {:ok, pos_integer()} | {:error, atom()}
  def validate_poll_interval_ms(value) when is_integer(value) do
    cond do
      value < 100 -> {:error, :too_small}
      value > 10_000 -> {:error, :too_large}
      true -> {:ok, value}
    end
  end

  def validate_poll_interval_ms(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:error, :blank}

      trimmed ->
        case Integer.parse(trimmed) do
          {int, ""} -> validate_poll_interval_ms(int)
          _ -> {:error, :not_an_integer}
        end
    end
  end

  @doc """
  Converts a `{field, reason}` tuple into a user-facing error string.
  """
  @spec error_message(atom(), atom() | String.t()) :: String.t()
  def error_message(:player_log_path, :blank), do: "Path cannot be blank."
  def error_message(:player_log_path, :not_a_file), do: "No file exists at that path."
  def error_message(:data_dir, :blank), do: "Path cannot be blank."
  def error_message(:data_dir, :not_a_directory), do: "No directory exists at that path."
  def error_message(:refresh_cron, :blank), do: "Cron expression cannot be blank."
  def error_message(:refresh_cron, reason) when is_binary(reason), do: "Invalid cron: #{reason}"
  def error_message(:refresh_cron, reason), do: "Invalid cron: #{inspect(reason)}"
  def error_message(:poll_interval_ms, :blank), do: "Interval cannot be blank."

  def error_message(:poll_interval_ms, :not_an_integer),
    do: "Must be a whole number of milliseconds."

  def error_message(:poll_interval_ms, :too_small), do: "Must be at least 100 ms."
  def error_message(:poll_interval_ms, :too_large), do: "Must be at most 10000 ms."
end
