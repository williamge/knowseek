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

  @typedoc "A document a source found. Same shape as `Knowseek.Documents.ingest/1` attrs, minus `:source`."
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
          optional(:share) => String.t()
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
end
