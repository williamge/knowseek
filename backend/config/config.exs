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
config :knowseek, Oban,
  engine: Oban.Engines.Basic,
  repo: Knowseek.Repo,
  queues: [discovery: 5],
  plugins: [{Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60}]

# Embedding provider. `dimensions` must match the `vector(N)` column size
# in the chunks table migration. The default is a local Ollama (ADR 0016);
# config/test.exs pins Hashing. config/runtime.exs reads EMBEDDINGS_ADAPTER to
# switch to Hashing or Voyage (see docs/decisions/0007-embedding-providers.md).
config :knowseek, Knowseek.Embeddings,
  adapter: Knowseek.Embeddings.Ollama,
  dimensions: 1024

# Search tuning and the coverage heuristic that decides when to seek new data.
# `max_age_seconds` is the default freshness need for a search. `nil` means
# that hits of any age count. A caller can override it per request.
# `candidate_factor`: each ranked list fetches `limit * candidate_factor`
# chunks, so grouping them by document still fills `limit` hits.
# `max_passages`: the most extra chunks a hit carries in `passages`.
# `prior_weight` and `prior_saturation_views`: the document prior (ADR 0018).
# A document's score is multiplied by 1 + prior_weight * min(1,
# log10(1 + views) / log10(1 + prior_saturation_views)), at most +30% by
# default. A weight of 0 turns the prior off.
config :knowseek, Knowseek.Search,
  default_limit: 10,
  candidate_factor: 40,
  max_passages: 3,
  min_similarity: 0.5,
  min_strong_hits: 3,
  max_age_seconds: nil,
  prior_weight: 0.3,
  prior_saturation_views: 1_000_000

# Discovery sources: modules that implement Knowseek.Discovery.Source.
config :knowseek, Knowseek.Discovery, sources: [Knowseek.Discovery.Sources.Wikipedia]

# Entity resolution (ADR 0017, task 030). `resolver` implements
# Knowseek.Entities.Resolver. `ttl`, `backoff` and `timeout` (milliseconds)
# go to Knowseek.Cache: entities rarely change, so a long TTL, and a failed
# Wikidata call is not retried for a minute. `max_query_length`: a longer
# query is not an entity name. `supported_types` says which Wikidata
# `instance of` ids make an entity a kind a card provider handles (see
# "Supported types" in the Knowseek.Entities docs). Ids marked "seen" appeared
# in the probes of tasks 028 and 030; the others were checked by label.
# `cache`: start options of the entity cache. Its keys come from user queries,
# so at most 4 Wikidata resolutions run at once and 5000 entries are kept.
config :knowseek, Knowseek.Entities,
  cache: [max_entries: 5_000, max_in_flight: 4],
  resolver: Knowseek.Entities.Wikidata,
  ttl: :timer.hours(24),
  backoff: :timer.minutes(1),
  timeout: :timer.seconds(15),
  max_alternatives: 5,
  max_query_length: 100,
  supported_types: [
    # Q13393265 basketball team (seen: New York Knicks, Westchester Knicks),
    # Q12973014 sports team, Q847017 sports club, Q476028 association
    # football club, Q13027888 baseball team, Q4498974 ice hockey team.
    sports_team: ["Q13393265", "Q12973014", "Q847017", "Q476028", "Q13027888", "Q4498974"],
    # Needs an exchange ticker (P414 with P249). Q891723 public company and
    # Q4830453 business (seen: Nvidia), Q783794 company. The screen reader
    # that `nvda` finds first has none of these.
    company: ["Q891723", "Q4830453", "Q783794"],
    # Needs coordinates (P625). Seen on Tokyo: Q1549591 big city, Q174844
    # megacity, Q208511 global city, Q200250 metropolis. Seen on its special
    # wards: Q515 city. Seen on Texas: Q35657 U.S. state. Seen on Japan:
    # Q6256 country, Q3624078 sovereign state, Q112099 island country (so
    # `weather in texas` and `weather in japan` resolve; the coordinates are
    # one point for the whole area). Also Q486972 human settlement, Q3957
    # town, Q532 village, Q5119 capital city, Q1637706 million city.
    place: [
      "Q515",
      "Q1549591",
      "Q174844",
      "Q208511",
      "Q200250",
      "Q486972",
      "Q3957",
      "Q532",
      "Q5119",
      "Q1637706",
      "Q35657",
      "Q6256",
      "Q3624078",
      "Q112099"
    ]
  ]

# Wikidata resolver. Wikimedia policy: identify the client in `user_agent`.
# `search_limit` candidates per query (the API allows 50). Tests put the
# Req.Test plug in `req_options` (config/test.exs).
config :knowseek, Knowseek.Entities.Wikidata,
  base_url: "https://www.wikidata.org/w/api.php",
  search_limit: 20,
  user_agent: "Knowseek/0.1.0 (https://github.com/williamge/knowseek)",
  req_options: []

# Live fact cards (ADR 0017, task 031). `providers` implement
# Knowseek.Cards.Provider and are tried in order. `backoff` and `timeout`
# (milliseconds) go to Knowseek.Cache: a failed ESPN fetch is not retried for
# 10 s (ESPN caches for 3 s), and a fetch (two parallel requests of 4 s at
# most) is killed after 12 s. `cache` holds the start options of the cards
# cache.
config :knowseek, Knowseek.Cards,
  providers: [Knowseek.Cards.Providers.EspnNba, Knowseek.Cards.Providers.OpenMeteo],
  backoff: :timer.seconds(10),
  timeout: :timer.seconds(12),
  cache: [max_entries: 1_000, max_in_flight: 8]

# ESPN's public site API. `receive_timeout` is per request.
config :knowseek, Knowseek.Cards.Espn,
  base_url: "https://site.api.espn.com/apis/site/v2/sports",
  user_agent: "Knowseek/0.1.0 (https://github.com/williamge/knowseek)",
  receive_timeout: 4_000,
  req_options: []

# Open-Meteo's forecast API (task 033, ADR 0022): no key; free for non-commercial
# use only, with attribution. `receive_timeout` is per request.
config :knowseek, Knowseek.Cards.OpenMeteo,
  base_url: "https://api.open-meteo.com/v1/forecast",
  user_agent: "Knowseek/0.1.0 (https://github.com/williamge/knowseek)",
  receive_timeout: 4_000,
  req_options: []

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
