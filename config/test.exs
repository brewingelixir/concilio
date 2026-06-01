import Config

# Storage backend (set at compile time; see lib/concilio/repo.ex).
db_choice = System.get_env("CONCILIO_DB", "sqlite")

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
case db_choice do
  "postgres" ->
    config :concilio, Concilio.Repo,
      username: "postgres",
      password: "postgres",
      hostname: "localhost",
      database: "concilio_test#{System.get_env("MIX_TEST_PARTITION")}",
      pool: Ecto.Adapters.SQL.Sandbox,
      pool_size: System.schedulers_online() * 2

  _ ->
    # SQLite is single-writer; we keep pool_size at 1 so async
    # sandboxes don't fight for the file's write lock and bail out
    # with `Exqlite.Error: Database busy`. Sandbox isolation comes
    # from transaction rollback, not from separate connections.
    config :concilio, Concilio.Repo,
      database:
        Path.expand(
          "../priv/repo/concilio_test#{System.get_env("MIX_TEST_PARTITION")}.db",
          __DIR__
        ),
      journal_mode: :wal,
      cache_size: -64_000,
      busy_timeout: 30_000,
      pool: Ecto.Adapters.SQL.Sandbox,
      pool_size: 1
end

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :concilio, ConcilioWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "XBKOKeDWVrDnsFxtI4ywAiI2rrWzHfy8D6iENxs8DorD9uX90lPzzoDdNUiZIIdD",
  server: false

# Disable Oban background processing during tests; jobs can be run
# inline or asserted on demand via Oban.Testing helpers.
config :concilio, Oban, testing: :manual

# Don't auto-bootstrap auth in tests; tests seed app_state directly via
# Concilio.Auth helpers when they need to.
config :concilio, :start_auth_bootstrapper?, false
config :concilio, :start_councils_bootstrapper?, false
config :concilio, :start_providers_bootstrapper?, false
config :concilio, :start_chat_recovery?, false
config :concilio, :start_settings?, false

config :concilio, Concilio.Settings,
  path:
    Path.join(
      System.tmp_dir!(),
      "concilio_settings_test_#{System.unique_integer([:positive])}.toml"
    )

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
