defmodule Knowseek.Entities.Resolver do
  @moduledoc """
  Behaviour for a place that turns text into candidate entities: Wikidata
  now, maybe an LLM step later (task 007).

  A resolver only finds candidates, with the details a card provider needs.
  Which candidate is the top entity is decided by `Knowseek.Entities`. A
  resolver never writes to the database.

  Register the module in config:

      config :knowseek, Knowseek.Entities, resolver: MyResolver
  """

  alias Knowseek.Entities.Entity

  @doc """
  Returns candidates for `text` (a place or a thing, with no intent words),
  best match first. An empty list means nothing matched. A timeout, a rate
  limit, or an HTTP error is `{:error, reason}`.
  """
  @callback search(text :: String.t(), opts :: keyword()) ::
              {:ok, [Entity.t()]} | {:error, term()}
end
