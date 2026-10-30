# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :knowseek,
  ecto_repos: [Knowseek.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Register the pgvector Postgrex extension (see lib/knowseek/postgrex_types.ex).
config :knowseek, Knowseek.Repo, types: Knowseek.PostgrexTypes

# Background jobs. Queues:
#   * discovery - seek new data from external sources for a query
#   * default   - everything else (topic refresh scheduling, etc.)
config :knowseek, Oban,
  engine: Oban.Engines.Basic,
  repo: Knowseek.Repo,
  queues: [default: 10, discovery: 5],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60},
    {Oban.Plugins.Cron, crontab: [{"*/15 * * * *", Knowseek.Topics.RefreshWorker}]}
  ]

# Embedding provider. `dimensions` must match the `vector(N)` column size
# in the chunks table migration. config/runtime.exs reads EMBEDDINGS_ADAPTER
# to switch to Ollama or Voyage (see docs/decisions/0007-embedding-providers.md).
config :knowseek, Knowseek.Embeddings,
  adapter: Knowseek.Embeddings.Hashing,
  dimensions: 1024

# Search tuning and the coverage heuristic that decides when to seek new data.
# `max_age_seconds` is the default freshness need for a search. `nil` means
# that hits of any age count. A caller can override it per request.
config :knowseek, Knowseek.Search,
  default_limit: 10,
  min_similarity: 0.5,
  min_strong_hits: 3,
  max_age_seconds: nil

# Discovery sources: modules that implement Knowseek.Discovery.Source.
config :knowseek, Knowseek.Discovery, sources: [Knowseek.Discovery.Sources.Wikipedia]

# Configure the endpoint
config :knowseek, KnowseekWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: KnowseekWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Knowseek.PubSub,
  live_view: [signing_salt: "89x625gM"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
