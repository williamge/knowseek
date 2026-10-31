defmodule Knowseek.Discovery.Source do
  @moduledoc """
  Behaviour for a place the service can seek new data: a web search API,
  an RSS feed, Wikipedia, an arXiv query, and so on.

  A source returns candidate documents. Discovery ingests them through
  `Knowseek.Documents.ingest/1`, so a source never writes to the index.

  Register sources in config:

      config :knowseek, Knowseek.Discovery, sources: [MySource]
  """

  @typedoc "A document a source found. Same shape as `Knowseek.Documents.ingest/1` attrs, minus `:source`."
  @type candidate :: %{
          required(:url) => String.t(),
          required(:body) => String.t(),
          optional(:title) => String.t(),
          optional(:published_at) => DateTime.t(),
          optional(:metadata) => map(),
          optional(:monthly_views) => non_neg_integer(),
          optional(:source_updated_at) => DateTime.t()
        }

  @doc "Short stable name. Stored in `documents.source`."
  @callback name() :: String.t()

  @doc "Finds documents relevant to `query`."
  @callback discover(query :: String.t(), opts :: keyword()) ::
              {:ok, [candidate()]} | {:error, term()}
end
