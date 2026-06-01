import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/concilio start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
# Storage backend (compile-time choice baked into Concilio.Repo;
# see lib/concilio/repo.ex). Mirrored in env so this runtime config
# can branch on the matching connection layout.
db_choice = System.get_env("CONCILIO_DB", "sqlite")

# Concilio's default distribution is a desktop app (Tauri shell)
# that expects the Phoenix endpoint up. We default `server: true`
# in prod so end users don't need to set anything; vanilla
# `bin/concilio start` users on Docker / Fly / VPS get the same.
# Explicit opt-out for IEx-only sessions: `PHX_SERVER=false`.
phx_server? =
  case config_env() do
    :prod -> System.get_env("PHX_SERVER", "true") not in ~w(false 0 no)
    _ -> System.get_env("PHX_SERVER") not in [nil, "false", "0", "no"]
  end

if phx_server? do
  config :concilio, ConcilioWeb.Endpoint, server: true
end

config :concilio, ConcilioWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Per-install secret loader. SQLite distribution ships as a binary
# end users run with no env vars — we cannot raise on missing
# `CONCILIO_SECRET` / `SECRET_KEY_BASE` at boot. Instead, generate
# them once on first launch and persist to `$DATA_DIR/secrets/`
# (mode 0600). Env vars override the file when set; this preserves
# the explicit-ops path for Postgres / hosted deploys.
current_env = config_env()

load_or_generate_secret = fn dir, name, env_var, byte_count ->
  case System.get_env(env_var) do
    value when is_binary(value) and value != "" ->
      value

    _ ->
      if current_env == :prod do
        File.mkdir_p!(dir)
        path = Path.join(dir, name)

        case File.read(path) do
          {:ok, contents} when byte_size(contents) > 0 ->
            String.trim(contents)

          _ ->
            generated =
              byte_count |> :crypto.strong_rand_bytes() |> Base.encode64(padding: false)

            File.write!(path, generated)
            File.chmod!(path, 0o600)
            generated
        end
      else
        "dev-only-not-secret-replace-with-#{env_var}-in-production"
      end
  end
end

# Data dir resolution. The default differs per env so dev / test /
# prod don't share `auth_token` (a single shared file would collide
# with each env's own `app_state.token_hash` and break login when
# you switch envs). Postgres prod deploys ignore this — they use
# their own infrastructure paths.
runtime_data_dir =
  case System.get_env("CONCILIO_DATA_DIR") do
    explicit when is_binary(explicit) and explicit != "" ->
      explicit

    _ ->
      case current_env do
        :prod ->
          Path.join(System.user_home!(), ".concilio")

        :dev ->
          Path.expand("../priv/.dev", __DIR__)

        :test ->
          Path.join(System.tmp_dir!(), "concilio_test_#{System.get_env("MIX_TEST_PARTITION")}")
      end
  end

if current_env != :prod or db_choice != "postgres" do
  File.mkdir_p!(runtime_data_dir)
end

# Make the resolved dir visible to the app at runtime. Used by
# `Concilio.Auth.TokenStore` (so `auth_token` lives next to the
# DB) and by anything else that wants per-env disk space.
config :concilio, :data_dir, runtime_data_dir

# CONCILIO_SECRET — base secret used to derive the encryption key for
# provider credentials stored in `provider_settings.encrypted_credentials`.
concilio_secret =
  load_or_generate_secret.(
    Path.join(runtime_data_dir, "secrets"),
    "concilio_secret",
    "CONCILIO_SECRET",
    48
  )

config :concilio, :concilio_secret, concilio_secret

# OPENROUTER_API_KEY is recognized as a hint for the providers UI to
# pre-fill the OpenRouter row on first boot. The credential of record
# always lives encrypted in the `provider_settings` row; this env var
# is never the source of truth at runtime.
config :concilio, :openrouter_api_key_hint, System.get_env("OPENROUTER_API_KEY")

if current_env == :prod do
  # Auto-run pending migrations on app boot. Tauri / packaged users
  # do not run `mix ecto.migrate`; vanilla `bin/concilio start`
  # deploys benefit from the same hook for cold-start safety.
  config :concilio, :auto_migrate?, true

  # SECRET_KEY_BASE — signs/encrypts cookies and LV tokens. Persisted
  # to disk on first launch so restarts don't invalidate sessions.
  secret_key_base =
    load_or_generate_secret.(
      Path.join(runtime_data_dir, "secrets"),
      "secret_key_base",
      "SECRET_KEY_BASE",
      48
    )

  config :concilio, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  case db_choice do
    "postgres" ->
      database_url =
        System.get_env("DATABASE_URL") ||
          raise """
          environment variable DATABASE_URL is missing.
          For example: ecto://USER:PASS@HOST/DATABASE
          """

      maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

      config :concilio, Concilio.Repo,
        url: database_url,
        pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
        socket_options: maybe_ipv6

    _ ->
      # SQLite is single-writer; pool_size > 1 only multiplies
      # contention. Override with POOL_SIZE if you have a specific
      # mostly-read workload.
      config :concilio, Concilio.Repo,
        database: Path.join(runtime_data_dir, "concilio.db"),
        journal_mode: :wal,
        cache_size: -64_000,
        busy_timeout: 30_000,
        pool_size: String.to_integer(System.get_env("POOL_SIZE") || "1")
  end

  # Concilio's distribution model is a local single-user app, so
  # we bind to loopback by default and skip the HTTPS scheme/host
  # ceremony. Reverse-proxy deploys override PORT / PHX_HOST /
  # PHX_BIND.
  bind_ip =
    case System.get_env("PHX_BIND") do
      "all" -> {0, 0, 0, 0, 0, 0, 0, 0}
      _ -> {127, 0, 0, 1}
    end

  host = System.get_env("PHX_HOST") || "localhost"
  port = String.to_integer(System.get_env("PORT", "4000"))

  # The Tauri WebView issues LiveView WebSocket upgrades from
  # `http://127.0.0.1:<dynamic-port>`, while the endpoint URL is
  # configured with `host: localhost`. Phoenix's default
  # `check_origin` rejects that mismatch. In app mode the endpoint
  # is bound to loopback and no remote traffic can reach it, so we
  # simply disable the origin check. Server deploys (non-app) keep
  # the default + the `:url[:host]` allowlist.
  endpoint_extra =
    if Application.get_env(:concilio, :app_mode?, false) do
      [check_origin: false]
    else
      []
    end

  config :concilio,
         ConcilioWeb.Endpoint,
         [
           url: [host: host, port: port, scheme: "http"],
           http: [ip: bind_ip, port: port],
           secret_key_base: secret_key_base
         ] ++ endpoint_extra
end
