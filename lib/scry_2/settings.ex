defmodule Scry2.Settings do
  @moduledoc """
  Context module for runtime key/value configuration persisted to SQLite.

  Owns table: `settings_entries`.

  PubSub role: broadcasts `"settings:updates"` after any mutation.

  Values are JSON-encoded so any term that round-trips through Jason can
  be stored. Use this for user preferences that belong with the database
  rather than the TOML file (which is for deployment-level config).

  ## Settings-over-Config fallback

  For keys that exist in both the TOML defaults (`Scry2.Config`) and the
  Settings table, always read through `get_or_config/2`. Settings wins
  when present; Config is the fallback. This lets the in-app Settings UI
  override TOML values at runtime without a restart.
  """

  alias Scry2.Config
  alias Scry2.Repo
  alias Scry2.Settings.Entry
  alias Scry2.Topics

  @doc "Returns all settings as a map of key => decoded value."
  def all do
    Entry
    |> Repo.all()
    |> Map.new(fn %Entry{key: k, value: v} -> {k, decode(v)} end)
  end

  @doc "Reads a setting, returning `default` if the key is not set."
  def get(key, default \\ nil) when is_binary(key) do
    case Repo.get(Entry, key) do
      nil -> default
      %Entry{value: v} -> decode(v)
    end
  end

  @doc """
  Reads a setting, falling back to `Scry2.Config.get/1` when the
  Settings table has no entry for `settings_key`.

  Use this for any key that exists in both TOML defaults and the
  Settings UI. Settings wins over Config when both are present.

  Safe to call during very early boot or from test contexts without a
  DB sandbox — if the Settings table is unreachable the Config value
  is returned.
  """
  @spec get_or_config(String.t(), atom()) :: term()
  def get_or_config(settings_key, config_key)
      when is_binary(settings_key) and is_atom(config_key) do
    case safe_get(settings_key) do
      nil -> Config.get(config_key)
      "" -> Config.get(config_key)
      value -> value
    end
  end

  defp safe_get(key) do
    get(key)
  rescue
    # Settings table may not be available in very early boot or in unit
    # tests that don't set up the sandbox. Fall back to Config.
    _ -> nil
  end

  @doc """
  Writes a setting. Any JSON-encodable term is accepted. Broadcasts
  `{:setting_changed, key}` to `"settings:updates"`.
  """
  def put!(key, value) when is_binary(key) do
    entry =
      case Repo.get(Entry, key) do
        nil -> %Entry{}
        existing -> existing
      end
      |> Entry.changeset(%{key: key, value: encode(value)})
      |> Repo.insert_or_update!()

    Topics.broadcast(Topics.settings_updates(), {:setting_changed, key})
    entry
  end

  @doc """
  Deletes a setting by key. No-op if the key does not exist.
  """
  @spec delete(String.t()) :: :ok
  def delete(key) when is_binary(key) do
    case Repo.get(Entry, key) do
      nil ->
        :ok

      entry ->
        Repo.delete(entry)
        Topics.broadcast(Topics.settings_updates(), {:setting_changed, key})
        :ok
    end
  end

  defp encode(value), do: Jason.encode!(value)

  defp decode(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _} -> value
    end
  end
end
