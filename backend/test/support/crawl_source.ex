defmodule Knowseek.Discovery.CrawlSource do
  @moduledoc """
  A discovery source for tests, named `"crawl"`, that lists a page's links for
  the background crawl (#89). It finds nothing by itself (`discover/2`).

  `link_candidates/2` answers from the test's own table: `Application.put_env(:knowseek,
  Knowseek.Discovery.CrawlSource, links: %{pageid => [%{page_id:, title:, description:}]})`,
  looked up by the `"pageid"` of the document's metadata (no entry means no links).
  A link without a `:url` gets `https://en.wikipedia.org/?curid=<page_id>`; one with
  its own `:url` keeps it (to test links off the allowlist). Every call reports 900
  downloaded bytes through `:on_bytes`, so a test can count the requests by the
  bytes recorded for `"crawl"`.
  """
  @behaviour Knowseek.Discovery.Source

  @impl true
  def name, do: "crawl"

  @impl true
  def discover(_query, _opts), do: {:ok, []}

  @impl true
  def link_candidates(document, opts) do
    if on_bytes = opts[:on_bytes], do: on_bytes.(900)

    links = :knowseek |> Application.get_env(__MODULE__, []) |> Keyword.get(:links, %{})

    candidates =
      links
      |> Map.get(document.metadata["pageid"], [])
      |> Enum.map(&Map.put_new(&1, :url, "https://en.wikipedia.org/?curid=#{&1.page_id}"))

    {:ok, candidates}
  end
end
