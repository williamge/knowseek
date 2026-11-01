defmodule Knowseek.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # A typo in the trusted proxies stops the start instead of trusting the wrong hosts.
    :ok = validate_trusted_proxies()

    children = [
      KnowseekWeb.Telemetry,
      Knowseek.Repo,
      {DNSCluster, query: Application.get_env(:knowseek, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Knowseek.PubSub},
      {Oban, Application.fetch_env!(:knowseek, Oban)},
      # In-memory, disposable caches with single-flight background refresh.
      {Knowseek.Cache, [name: Knowseek.Entities.Cache] ++ cache_options(Knowseek.Entities)},
      {Knowseek.Cache, [name: Knowseek.Cards.Cache] ++ cache_options(Knowseek.Cards)},
      # The ESPN team list: one key, one long TTL.
      {Knowseek.Cache, name: Knowseek.Cards.EspnTeams, max_entries: 10},
      # Per-client request limits of the anonymous endpoints (ADR 0023).
      {Knowseek.RateLimiter, [name: Knowseek.RateLimiter] ++ rate_limiter_options()},
      # Start to serve requests, typically the last entry
      KnowseekWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Knowseek.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Start options of a context's cache (config `:cache`).
  defp cache_options(context),
    do: Application.fetch_env!(:knowseek, context) |> Keyword.get(:cache, [])

  defp validate_trusted_proxies do
    :knowseek
    |> Application.get_env(KnowseekWeb.RateLimit, [])
    |> Keyword.get(:trusted_proxies, [])
    |> KnowseekWeb.ClientIp.cidrs!()

    :ok
  end

  defp rate_limiter_options,
    do: Application.get_env(:knowseek, Knowseek.RateLimiter, [])

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    KnowseekWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
