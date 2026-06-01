# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Storage backend choice (compile time only). See lib/concilio/repo.ex.
# `db_choice` is reused below to pick the matching Oban engine.
db_choice = System.get_env("CONCILIO_DB", "sqlite")

# App-mode flag — set to "1" / "true" by the Tauri shell (and by
# the release-CI matrix) so a single mix.exs builds either a
# vanilla server release or a desktop-app release. App mode opens
# the LiveDashboard route, may relax CSP, and switches the default
# bind to a dynamic port. See lib/concilio_web/router.ex.
app_mode? = System.get_env("CONCILIO_APP") in ~w(1 true yes)
config :concilio, app_mode?: app_mode?

config :concilio,
  ecto_repos: [Concilio.Repo],
  generators: [timestamp_type: :utc_datetime]

# council_ex publishes run events on this PubSub instance. Concilio.PubSub
# is started by the Phoenix scaffold (see Concilio.Application). council_ex
# itself does not start Phoenix.PubSub.
config :council_ex,
  pubsub: {CouncilEx.PubSub.Phoenix, name: Concilio.PubSub}

# Register the bundled CouncilEx profiles + schemas under standard names so
# the dynamic-council builder's profile/output-schema selects have a useful
# default set. Users can extend at runtime via `CouncilEx.Registry.register_*/2`.
config :council_ex, :registry,
  profiles: %{
    "openai_mini" => CouncilEx.Profiles.OpenAIMini,
    "openai_balanced" => CouncilEx.Profiles.OpenAIBalanced,
    "openai_creative" => CouncilEx.Profiles.OpenAICreative,
    "openai_deterministic" => CouncilEx.Profiles.OpenAIDeterministic,
    "anthropic_balanced" => CouncilEx.Profiles.AnthropicBalanced,
    "gemini_balanced" => CouncilEx.Profiles.GeminiBalanced,
    "ollama_local" => CouncilEx.Profiles.OllamaLocal,
    "open_router_auto" => CouncilEx.Profiles.OpenRouterAuto,
    "open_router_claude_sonnet" => CouncilEx.Profiles.OpenRouterClaudeSonnet
  },
  schemas: %{
    "critique" => CouncilEx.Schemas.Critique,
    "ranking" => CouncilEx.Schemas.Ranking,
    "vote" => CouncilEx.Schemas.Vote
  }

# Oban — single instance, single Repo. Engine matches the storage
# choice: `Lite` for SQLite (polling-based; no LISTEN/NOTIFY),
# `Basic` for Postgres (LISTEN/NOTIFY-driven).
oban_engine =
  case db_choice do
    "postgres" -> Oban.Engines.Basic
    _ -> Oban.Engines.Lite
  end

config :concilio, Oban,
  repo: Concilio.Repo,
  engine: oban_engine,
  queues: [default: 10, providers: 4, cleanup: 1],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Cron,
     crontab: [
       # Nightly run_events cleanup at 03:17
       {"17 3 * * *", Concilio.Workers.Cleanup}
     ]}
  ]

# Configure the endpoint
config :concilio, ConcilioWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ConcilioWeb.ErrorHTML, json: ConcilioWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Concilio.PubSub,
  live_view: [signing_salt: "wW0Nal8Z"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  concilio: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  concilio: [
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

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
