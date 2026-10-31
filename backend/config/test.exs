import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
#
# Each workspace gets its own test database (see config/dev.exs).
db_suffix =
  case System.get_env("KNOWSEEK_WORKSPACE") || System.get_env("CONDUCTOR_WORKSPACE_NAME") do
    nil -> ""
    name -> "_" <> String.replace(String.downcase(name), ~r/[^a-z0-9]+/, "_")
  end

config :knowseek, Knowseek.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  database: "knowseek_test#{db_suffix}#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :knowseek, KnowseekWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "gTqr1hg7IZsoVzaQKESX+bZ0JjEr2XOY0TJCA1V6NcDgM2j3Z/5D76QZl5e9Z+Qp",
  server: false

# Jobs are inserted but not run. Use Oban.Testing helpers to assert on them
# or perform them explicitly.
config :knowseek, Oban, testing: :manual

# Tests never need Ollama or the network: the adapter is Hashing unless a test
# switches it. Ollama and Voyage requests go to Req.Test stubs. Retries do not
# sleep.
config :knowseek, Knowseek.Embeddings, adapter: Knowseek.Embeddings.Hashing

config :knowseek, Knowseek.Embeddings.Ollama,
  req_options: [
    plug: {Req.Test, Knowseek.Embeddings.Ollama},
    retry_delay: 0,
    retry_log_level: false
  ]

config :knowseek, Knowseek.Embeddings.Voyage,
  api_key: "test-key",
  req_options: [
    plug: {Req.Test, Knowseek.Embeddings.Voyage},
    retry_delay: 0,
    retry_log_level: false
  ]

# Tests never call real sources. Tests that need one pass `sources:` to
# `Knowseek.Discovery.run/2`, and stub its HTTP calls with Req.Test.
config :knowseek, Knowseek.Discovery, sources: []

config :knowseek, Knowseek.Discovery.Sources.Wikipedia,
  req_options: [plug: {Req.Test, Knowseek.Discovery.Sources.Wikipedia}, retry: false]

config :knowseek, Knowseek.Entities.Wikidata,
  req_options: [plug: {Req.Test, Knowseek.Entities.Wikidata}, retry: false]

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
