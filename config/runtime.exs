import Config

# Enables the Phoenix HTTP server when the PHX_SERVER env var is set,
# or automatically when running as a mix release (RELEASE_NAME is set
# by the release launcher).
if System.get_env("PHX_SERVER") || System.get_env("RELEASE_NAME") do
  config :scry_2, Scry2Web.Endpoint, server: true
end

if config_env() == :prod do
  # ── Bootstrap config resolution ─────────────────────────────────────────
  # Read config.toml if present. On first run it may not exist yet —
  # Scry2.Config.load!/0 will generate it during Application.start/2.
  toml_path = Scry2.Platform.config_path()

  toml =
    with {:ok, contents} <- File.read(toml_path),
         {:ok, parsed} <- Toml.decode(contents) do
      parsed
    else
      _ -> %{}
    end

  # HTTP port: PORT env var → TOML [server][port] → 4002.
  # Set [server] port = 4003 in ~/.config/scry_2/config.toml to run a
  # production release alongside a dev server on the same machine.
  port =
    case System.get_env("PORT") do
      nil -> get_in(toml, ["server", "port"]) || 4002
      p -> String.to_integer(p)
    end

  # Platform-appropriate default database path (used on first run before
  # config.toml exists).
  default_db_path = Path.join(Scry2.Platform.data_dir(), "scry_2.db")

  database_path =
    System.get_env("DATABASE_PATH") ||
      get_in(toml, ["database", "path"]) ||
      default_db_path

  config :scry_2, Scry2.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5"),
    journal_mode: :wal,
    busy_timeout: 5_000

  # Secret key base: env var → TOML → random.
  # On first boot the TOML doesn't exist yet, so a random key is used for
  # that one boot. Scry2.Config.load!/0 writes the TOML (with a stable key)
  # during Application.start/2, so all subsequent boots use the persisted key.
  # For a localhost-only app this one-boot inconsistency is harmless
  # (no persistent sessions are lost; LiveView just reconnects).
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      toml["secret_key_base"] ||
      Base.encode64(:crypto.strong_rand_bytes(64))

  config :scry_2, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :scry_2, Scry2Web.Endpoint,
    url: [host: "localhost", port: port, scheme: "http"],
    http: [
      # Bind to localhost only — this is a local desktop tool, not a server.
      ip: {127, 0, 0, 1},
      port: port
    ],
    secret_key_base: secret_key_base
end
