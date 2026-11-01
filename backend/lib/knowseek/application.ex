defmodule Knowseek.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        KnowseekWeb.Telemetry,
        Knowseek.Repo,
        {DNSCluster, query: Application.get_env(:knowseek, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Knowseek.PubSub},
        {Oban, Application.fetch_env!(:knowseek, Oban)},
        # In-memory, disposable caches with single-flight background refresh.
        {Knowseek.Cache, [name: Knowseek.Entities.Cache] ++ cache_options(Knowseek.Entities)}
        # One per card provider: a rate limit stops all fetches of a cache.
      ] ++
        card_caches() ++
        [
          # The ESPN team list: one key, one long TTL.
          {Knowseek.Cache, name: Knowseek.Cards.EspnTeams, max_entries: 10},
          # Start to serve requests, typically the last entry
          KnowseekWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Knowseek.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp card_caches do
    for provider <- Application.fetch_env!(:knowseek, Knowseek.Cards)[:providers] do
      {Knowseek.Cache,
       [name: Knowseek.Cards.cache_name(provider)] ++ Knowseek.Cards.cache_options(provider)}
    end
  end

  # Start options of a context's cache (config `:cache`).
  defp cache_options(context),
    do: Application.fetch_env!(:knowseek, context) |> Keyword.get(:cache, [])

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    KnowseekWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
