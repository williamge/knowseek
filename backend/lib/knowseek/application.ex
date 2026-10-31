defmodule Knowseek.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      KnowseekWeb.Telemetry,
      Knowseek.Repo,
      {DNSCluster, query: Application.get_env(:knowseek, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Knowseek.PubSub},
      {Oban, Application.fetch_env!(:knowseek, Oban)},
      # In-memory, disposable caches with single-flight background refresh.
      {Knowseek.Cache, name: Knowseek.Entities.Cache},
      # Start to serve requests, typically the last entry
      KnowseekWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Knowseek.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    KnowseekWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
