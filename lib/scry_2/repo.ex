defmodule Scry2.Repo do
  use Ecto.Repo,
    otp_app: :scry_2,
    adapter: Ecto.Adapters.SQLite3

  @doc """
  Overrides the database path at runtime from the user's TOML config file.

  Runs before the Repo process starts (and before the Config GenServer),
  so it reads the TOML file directly rather than going through Config.

  In test (Sandbox pool), the TOML override is skipped so tests use the
  dedicated test database configured in `config/test.exs`.
  """
  @impl true
  def init(_context, config) do
    database_path =
      if config[:pool] == Ecto.Adapters.SQL.Sandbox do
        config[:database]
      else
        read_database_path_from_toml() || config[:database]
      end

    :ok = ensure_directory(database_path)
    {:ok, Keyword.put(config, :database, database_path)}
  end

  defp read_database_path_from_toml do
    path = Scry2.Config.config_path()

    with {:ok, contents} <- File.read(path),
         {:ok, toml} <- Toml.decode(contents),
         database_path when is_binary(database_path) <-
           get_in(toml, ["database", "path"]) do
      Path.expand(database_path)
    else
      _ -> nil
    end
  end

  defp ensure_directory(path) when is_binary(path) do
    path |> Path.dirname() |> File.mkdir_p!()
    :ok
  end

  defp ensure_directory(_), do: :ok
end
