defmodule KnowseekWeb.BlockedLinkJSON do
  @doc "The blocked-link log: totals, and up to 200 domains."
  def index(%{log: log, allowed_hosts: allowed_hosts}) do
    %{
      data: %{
        allowed_hosts: allowed_hosts,
        total_domains: log.total_domains,
        total_links: log.total_links,
        domains: log.domains
      }
    }
  end

  def backfill(%{enqueued: enqueued}), do: %{data: %{enqueued: enqueued}}
end
