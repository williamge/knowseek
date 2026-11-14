defmodule Knowseek.Discovery.Source do
  @moduledoc """
  Behaviour for a place the service can seek new data: a web search API,
  an RSS feed, Wikipedia, an arXiv query, and so on.

  A source returns candidate documents. Discovery ingests them through
  `Knowseek.Documents.ingest/1`, so a source never writes to the index.

  Register sources in config:

      config :knowseek, Knowseek.Discovery, sources: [MySource]

  A source sets the license fields per document (ADR 0026): `:license` (SPDX
  id), `:attribution` (`%{url:, credit:, authors:}`), `:modified` and `:share`
  (`"full"`, `"pointer"` or `"none"`). Left out, a new document is unknown and
  never shared.
  """

  @typedoc """
  A document a source found. Same shape as `Knowseek.Documents.ingest/1` attrs, minus `:source`.

  `:links` is the page's outgoing links as the source found them (absolute or
  protocol-relative URLs). `Knowseek.Discovery` logs the ones to hosts off the
  allowlist and never passes them to `Knowseek.Documents.ingest/1`.
  """
  @type candidate :: %{
          required(:url) => String.t(),
          required(:body) => String.t(),
          optional(:title) => String.t(),
          optional(:published_at) => DateTime.t(),
          optional(:metadata) => map(),
          optional(:monthly_views) => non_neg_integer(),
          optional(:source_updated_at) => DateTime.t(),
          optional(:license) => String.t(),
          optional(:attribution) => %{url: String.t(), credit: String.t(), authors: [String.t()]},
          optional(:modified) => boolean(),
          optional(:share) => String.t(),
          optional(:links) => [String.t()]
        }

  @doc "Short stable name. Stored in `documents.source`."
  @callback name() :: String.t()

  @doc """
  Finds documents relevant to `query`.

  `opts` may hold `:on_bytes`, a function of one argument. A source that
  downloads calls it with the body size in bytes of every HTTP response it
  receives. It must not write anything itself (rule 3).
  """
  @callback discover(query :: String.t(), opts :: keyword()) ::
              {:ok, [candidate()]} | {:error, term()}

  @doc """
  The outgoing links of a page this source produced earlier, for the link
  backfill. `document` is the stored document (it has the `metadata` the
  source set). Optional: a source without it is skipped by the backfill.
  """
  @callback links(document :: %{required(:metadata) => map()}, opts :: keyword()) ::
              {:ok, [String.t()]} | {:error, term()}

  @typedoc """
  A page that a stored page links to, before it is fetched: its page id on the
  source's site, its title, its short description (`nil` when it has none) and
  a URL of the page on the site, which `Knowseek.Discovery.allowed?/1` checks.
  """
  @type link_candidate :: %{
          page_id: integer(),
          title: String.t(),
          description: String.t() | nil,
          url: String.t()
        }

  @doc """
  The pages that a page this source produced earlier links to on the same
  site, for the background crawl (#89). Optional. `opts` may hold `:on_bytes`.
  """
  @callback link_candidates(document :: %{required(:metadata) => map()}, opts :: keyword()) ::
              {:ok, [link_candidate()]} | {:error, term()}

  @doc """
  One page by the id the source gave it in `link_candidates/2`, as a
  candidate; `nil` when the page has no text to index. For the background
  crawl (#89). Optional. `opts` may hold `:on_bytes`.
  """
  @callback page(page_id :: integer(), opts :: keyword()) ::
              {:ok, candidate() | nil} | {:error, term()}

  @optional_callbacks links: 2, link_candidates: 2, page: 2
end
