defmodule Knowseek.Discovery.Sources.Wikipedia do
  @moduledoc """
  Discovery source for English Wikipedia, through the MediaWiki Action API
  (`Knowseek.Discovery.Sources.MediaWiki`, which documents the requests and
  the candidates). Runs for every query.

  Candidates are `CC-BY-SA-4.0` (Wikipedia text is CC BY-SA 4.0 or GFDL;
  reusers may pick either), credited to "Wikipedia" with a link to the page,
  `modified: true` and `share: "full"` (ADR 0026).

  Configuration (all optional; see `Knowseek.Discovery.Sources.MediaWiki`):

      config :knowseek, Knowseek.Discovery.Sources.Wikipedia,
        base_url: "https://en.wikipedia.org/w/api.php",
        limit: 3,
        max_chars: 40_000,
        user_agent: "...",
        req_options: []
  """
  @behaviour Knowseek.Discovery.Source

  alias Knowseek.Discovery.Sources.MediaWiki

  @site %{
    name: "wikipedia",
    base_url: "https://en.wikipedia.org/w/api.php",
    license: "CC-BY-SA-4.0",
    credit: "Wikipedia",
    config: __MODULE__
  }

  @impl true
  def name, do: @site.name

  @impl true
  def discover(query, _opts), do: MediaWiki.discover(query, @site)
end
