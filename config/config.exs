# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :scry_2,
  ecto_repos: [Scry2.Repo],
  generators: [timestamp_type: :utc_datetime]

# Scry2.Collection reads MTGA process memory through a pluggable backend.
# Dev/prod use the Rustler NIF; tests swap in TestBackend via config/test.exs.
# See ADR 034.
config :scry_2, Scry2.MtgaMemory, impl: Scry2.MtgaMemory.Nif

# Log Ecto queries at :info (not the Ecto default of :debug). Scry2 is a
# single-user desktop app — query visibility is a diagnostic feature, not
# production noise. This applies in dev AND prod so the user can flip the
# `ecto` chip in the Console drawer and immediately see queries without
# also having to drop the level floor to :debug.
config :scry_2, Scry2.Repo, log: :info

# Oban (SQLite backend via Oban.Engines.Lite)
config :scry_2, Oban,
  engine: Oban.Engines.Lite,
  repo: Scry2.Repo,
  queues: [default: 5, imports: 1, self_update: 1, collection: 1],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       # Daily 04:30 UTC — re-import the MTGA client card database so
       # new sets get picked up shortly after MTGA's content patch.
       {"30 4 * * *", Scry2.Workers.PeriodicallyImportMtgaClientCards},
       # Weekly Sunday 05:00 UTC — refresh Scryfall bulk data into
       # cards_scryfall_cards (oracle metadata, image URIs, rotated cards).
       {"0 5 * * 0", Scry2.Workers.PeriodicallyImportScryfallCards},
       # Daily 05:30 UTC — synthesise cards_cards from MTGA + Scryfall.
       # Runs after both upstream imports have had a chance to refresh.
       {"30 5 * * *", Scry2.Workers.PeriodicallySynthesizeCards},
       # Hourly at :17 — check GitHub Releases for a new Scry2 version.
       # Offset from the :00 slots above so the cron firings don't pile up.
       {"17 * * * *", Scry2.SelfUpdate.CheckerJob, args: %{"trigger" => "cron"}}
     ]}
  ]

# Trigger a background update check when a LiveView mounts and the
# persistent_term cache is stale. Kept true in dev/prod so the
# System tab always shows current release info without a user click;
# overridden to false in test to avoid hitting the GitHub API.
config :scry_2, :auto_check_updates_on_mount, true

# Configure the endpoint
config :scry_2, Scry2Web.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: Scry2Web.ErrorHTML, json: Scry2Web.ErrorJSON],
    layout: false
  ],
  pubsub_server: Scry2.PubSub,
  live_view: [signing_salt: "Lxv6fW83"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  scry_2: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  scry_2: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Capture SASL reports (supervisor crash/progress reports) so when a
# child process dies the diagnostic information ends up in our log
# file. Without this, OTP filters those reports out by default and the
# only evidence of "child X crashed Y times before the supervisor gave
# up" lives in the in-memory ring buffer that's lost on BEAM exit.
config :logger, handle_sasl_reports: true

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
