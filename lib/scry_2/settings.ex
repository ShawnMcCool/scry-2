defmodule Scry2.Settings do
  @moduledoc """
  Context module for runtime key/value configuration persisted to SQLite.

  Owns table: `settings_entries`.

  PubSub role: broadcasts `"settings:updates"` after any mutation.

  Values are JSON-encoded so any term that round-trips through Jason can
  be stored. Use this for user preferences that belong with the database
  rather than the TOML file (which is for deployment-level config).
  """

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

  defp encode(value), do: Jason.encode!(value)

  defp decode(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _} -> value
    end
  end
end
