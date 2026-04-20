defmodule Scry2.SelfUpdate.Storage do
  @moduledoc """
  Durable backing for self-update check state. Values are stored via
  `Scry2.Settings` (SQLite JSON blobs) under two keys:

    - `updates.last_check_at` — ISO 8601 timestamp of last check attempt
      (updated even on errors, so the UI can show "checked 3 min ago")
    - `updates.latest_known` — the most recent successful release map

  `hydrate!/0` seeds the `UpdateChecker` `:persistent_term` cache at boot
  so the UI has data immediately, even before the first live check.
  """

  alias Scry2.Settings
  alias Scry2.SelfUpdate.UpdateChecker

  @last_check_key "updates.last_check_at"
  @latest_known_key "updates.latest_known"

  @spec last_check_at() :: String.t() | nil
  def last_check_at, do: Settings.get(@last_check_key)

  @spec latest_known() :: {:ok, UpdateChecker.release()} | :none
  def latest_known do
    case Settings.get(@latest_known_key) do
      nil ->
        :none

      raw when is_map(raw) ->
        {:ok,
         %{
           tag: raw["tag"],
           version: raw["version"],
           published_at: raw["published_at"],
           html_url: raw["html_url"] || "",
           body: raw["body"] || ""
         }}
    end
  end

  @spec record_check_result({:ok, UpdateChecker.release()} | {:error, term()}) :: :ok
  def record_check_result({:ok, release}) do
    Settings.put!(@last_check_key, DateTime.utc_now() |> DateTime.to_iso8601())
    Settings.put!(@latest_known_key, stringify_keys(release))
    UpdateChecker.put_cache(release)
    :ok
  end

  def record_check_result({:error, _reason}) do
    Settings.put!(@last_check_key, DateTime.utc_now() |> DateTime.to_iso8601())
    :ok
  end

  @spec hydrate!() :: :ok
  def hydrate! do
    case latest_known() do
      {:ok, release} -> UpdateChecker.put_cache(release)
      :none -> :ok
    end

    :ok
  end

  @doc "Test-only: remove both keys."
  @spec clear_all!() :: :ok
  def clear_all! do
    _ = Settings.delete(@last_check_key)
    _ = Settings.delete(@latest_known_key)
    :ok
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
