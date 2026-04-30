import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :scry_2, Scry2.Repo,
  database: Path.expand("../scry_2_test#{System.get_env("MIX_TEST_PARTITION")}.db", __DIR__),
  # SQLite is single-writer. Pool size 1 is the idiomatic ecto_sqlite3 test
  # pattern: the Sandbox pool serializes checkouts, each async test runs its
  # transaction in sequence, and we never see "Database busy" races. True
  # cross-test parallelism comes from MIX_TEST_PARTITION, not pool depth.
  pool_size: 1,
  pool: Ecto.Adapters.SQL.Sandbox,
  journal_mode: :wal,
  busy_timeout: 15_000,
  default_transaction_mode: :immediate

# Don't start the MTGA log watcher or card importers during tests.
# Tests that need these exercise them directly via the module API.
config :scry_2, start_watcher: false, start_importer: false

# Run Oban in :inline mode for tests — no supervision tree, no background
# processes contending with the Sandbox-owned connection. Workers run
# synchronously in the calling process when enqueued via `Oban.insert`.
config :scry_2, Oban, testing: :inline

# LiveViews normally kick off a background GitHub check on mount so the
# Updates card is always populated. Tests don't set up a Req stub, so
# disable the auto-trigger globally — tests that exercise the update
# flow enqueue CheckerJob directly with a stub.
config :scry_2, :auto_check_updates_on_mount, false

# Skip TOML user-config lookup during tests — use only built-in defaults
# unless a test explicitly opts in via Application.put_env/3.
config :scry_2, skip_user_config: true

# Swap MtgaMemory's backend for the in-memory fixture in tests so
# reader/walker/live-state unit tests don't need a live MTGA. See ADR 034.
config :scry_2, Scry2.MtgaMemory, impl: Scry2.MtgaMemory.TestBackend

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :scry_2, Scry2Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4444],
  secret_key_base: "ZYOB18YhLALbK7xneBtbxrvmsK6wE/DxePNtu6lsLJ01DBejHcpk7cTgB6NZ31UO",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Don't install the Scry2 console :logger handler during tests — it bypasses
# ExUnit's capture_log mechanism and causes expected cross-process warnings
# to leak into test output.
config :scry_2, install_console_handler: false

# Skip the file log handler during tests — there's no need for log files
# under data_dir/log/scry_2.log when running ExUnit, and the disk_log
# wrapper is global state.
config :scry_2, install_file_log_handler: false

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
