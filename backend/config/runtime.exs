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
#     PHX_SERVER=true bin/knowseek start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :knowseek, KnowseekWeb.Endpoint, server: true
end

config :knowseek, KnowseekWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Embeddings. EMBEDDINGS_ADAPTER selects the provider:
#   * hashing (default) - local stand-in, no semantics
#   * ollama            - local model through Ollama (`make ollama`), free
#   * voyage            - Voyage AI API, needs VOYAGE_API_KEY
# Tests always use Hashing or a Req.Test stub, so this block is skipped there.
# Switching adapters makes stored vectors incomparable: re-embed after a switch.
env = fn name, default ->
  case System.get_env(name) do
    value when value in [nil, ""] -> default
    value -> value
  end
end

if config_env() != :test do
  config :knowseek, Knowseek.Embeddings.Ollama,
    base_url: env.("OLLAMA_URL", "http://localhost:11434"),
    model: env.("OLLAMA_MODEL", "bge-m3")

  config :knowseek, Knowseek.Embeddings.Voyage,
    api_key: env.("VOYAGE_API_KEY", nil),
    model: env.("VOYAGE_MODEL", "voyage-3.5")

  adapter =
    case env.("EMBEDDINGS_ADAPTER", "hashing") do
      "hashing" ->
        Knowseek.Embeddings.Hashing

      "ollama" ->
        Knowseek.Embeddings.Ollama

      "voyage" ->
        env.("VOYAGE_API_KEY", nil) ||
          raise "EMBEDDINGS_ADAPTER=voyage needs the VOYAGE_API_KEY environment variable"

        Knowseek.Embeddings.Voyage

      other ->
        raise "unknown EMBEDDINGS_ADAPTER #{inspect(other)}; use hashing, ollama, or voyage"
    end

  config :knowseek, Knowseek.Embeddings, adapter: adapter
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :knowseek, Knowseek.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :knowseek, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :knowseek, KnowseekWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :knowseek, KnowseekWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :knowseek, KnowseekWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
