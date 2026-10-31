defmodule Knowseek.Entities do
  @moduledoc """
  Entity resolution: turns a search query into the entity it is about (and
  alternatives) that a card provider can use. Decided in ADR 0017; the cards
  (tasks 031-034) are its callers.

  `resolve/2` is cache-only, like the cards. It reads the in-memory cache of
  `Knowseek.Cache` and never calls Wikidata in the caller's process:

    * A cold query returns `{:pending, query}` at once and starts one
      single-flight fetch in a supervised task. The caller polls: the next
      call that finds the result returns it.
    * The answer, including "nothing matches" (`:none`), is cached for a long
      TTL (`:ttl`, a day by default), because entities rarely change. An
      expired answer is still returned while it is refreshed. A failed refresh
      keeps it.
    * A failure with nothing cached (timeout, HTTP 429, any HTTP error) is
      `{:error, reason}`, and no new fetch starts until the `:backoff` ends.

  Search must keep working without an entity: callers treat `{:pending, _}`,
  `:none` and `{:error, _}` as "no card". Nothing here writes to the database.

  ## Which entity is the top entity

  The query is split first (`Knowseek.Entities.Intent`): `weather in tokyo`
  resolves the text `tokyo` and returns `intent: :weather`. The resolver
  (`Knowseek.Entities.Resolver`, Wikidata by default) returns candidates
  best match first. The top entity is the first candidate with a *kind*
  (`kind/1`), not simply the first candidate: the search for a ticker such as
  `nvda` puts a screen reader first. The other candidates of the same kind,
  at most `:max_alternatives`, in search order, are the `alternatives` (for
  example the Westchester Knicks). No candidate with a kind is `:none`.

  ## Supported types

  A card provider handles a kind of entity. The kinds and the Wikidata
  `instance of` ids that make an entity one are config
  (`:supported_types`, a keyword list of kind to type ids). An entity has the
  first kind (in config order) for which both hold:

    1. One of its `types` is in the kind's list.
    2. It has what the provider needs: for `:company`, an exchange ticker
       (`exchange_tickers` is not empty); for `:place`, `coordinates`.
       `:sports_team` needs nothing more.

  The rule is deliberately a flat list, not Wikidata's `subclass of` tree:
  Tokyo is a *big city*, a *megacity*, a *global city*, and a *capital of
  Japan* at once, and none of these is a Q515 *city*. A type that is not in
  the list is not supported until it is added to the config. Unsupported
  entities are not an error; they are skipped.

  ## Configuration

  See `config/config.exs`: `resolver`, `ttl`, `backoff`, `timeout`,
  `max_alternatives`, `max_query_length` (longer queries are `:none`: no one
  names an entity in a paragraph), `supported_types`. `config/config.exs`
  lists the Wikidata ids seen in the probes of task 028 and task 030.
  """

  alias Knowseek.Cache
  alias Knowseek.Entities.{Entity, Intent}

  @cache Knowseek.Entities.Cache

  @type intent :: Intent.intent()
  @type kind :: atom()
  @type resolution :: %{intent: intent(), entity: Entity.t(), alternatives: [Entity.t()]}

  @doc """
  Resolves `query`.

    * `{:ok, %{intent: intent, entity: entity, alternatives: [entity]}}`
    * `:none` - nothing useful matches (or the query is blank or too long)
    * `{:pending, query}` - cold cache: a fetch was started, ask again later
    * `{:error, reason}` - the last fetch failed and nothing is cached

  Options (for tests): `:cache` (a started `Knowseek.Cache` name) and
  `:resolver` (a `Knowseek.Entities.Resolver` module).
  """
  @spec resolve(String.t(), keyword()) ::
          {:ok, resolution()} | :none | {:pending, String.t()} | {:error, term()}
  def resolve(query, opts \\ []) when is_binary(query) do
    {intent, text} = Intent.split(query)
    config = config(opts)

    case cache_key(text, config) do
      nil -> :none
      key -> read(key, text, intent, query, config)
    end
  end

  defp read(key, text, intent, query, config) do
    case Cache.get(config.cache, key, fn -> fetch(text, config) end, cache_options(config)) do
      {status, value, _as_of} when status in [:fresh, :stale] -> present(value, intent)
      :pending -> {:pending, query}
      {:unavailable, reason} -> {:error, reason}
    end
  end

  @doc """
  Blocks until the fetch running for `query` (if any) has finished. For tests
  and scripts that need the result of a `{:pending, _}`; same options as
  `resolve/2`, plus `:timeout` (default 5000).
  """
  @spec await(String.t(), keyword()) :: :ok
  def await(query, opts \\ []) when is_binary(query) do
    {_intent, text} = Intent.split(query)
    config = config(opts)

    case cache_key(text, config) do
      nil -> :ok
      key -> Cache.await(config.cache, key, Keyword.get(opts, :timeout, 5_000))
    end
  end

  @doc """
  Picks the top entity and the alternatives from `candidates` (best match
  first), by the rule in the module doc. Returns `:none` when no candidate
  has a kind.
  """
  @spec choose([Entity.t()]) ::
          {:ok, %{entity: Entity.t(), alternatives: [Entity.t()]}} | :none
  def choose(candidates) when is_list(candidates), do: choose(candidates, config([]))

  defp choose(candidates, config) do
    case Enum.find_value(candidates, &top_with_kind(&1, config)) do
      nil ->
        :none

      {entity, kind} ->
        alternatives =
          candidates
          |> Enum.reject(&(&1.id == entity.id))
          |> Enum.filter(&(kind(&1, config.supported_types) == kind))
          |> Enum.take(config.max_alternatives)

        {:ok, %{entity: entity, alternatives: alternatives}}
    end
  end

  @doc """
  The kind of `entity` (`:sports_team`, `:company`, `:place`, ...), or `nil`
  when no provider handles it. See "Supported types" in the module doc.
  """
  @spec kind(Entity.t()) :: kind() | nil
  def kind(%Entity{} = entity), do: kind(entity, config([]).supported_types)

  defp kind(entity, supported_types) do
    Enum.find_value(supported_types, fn {kind, type_ids} ->
      if Enum.any?(entity.types, &(&1 in type_ids)) and complete?(kind, entity), do: kind
    end)
  end

  defp complete?(:company, entity), do: entity.exchange_tickers != []
  defp complete?(:place, entity), do: entity.coordinates != nil
  defp complete?(_kind, _entity), do: true

  defp top_with_kind(entity, config) do
    if kind = kind(entity, config.supported_types), do: {entity, kind}
  end

  # Runs in the cache's task, never in the caller.
  defp fetch(text, config) do
    with {:ok, candidates} <- config.resolver.search(text, []) do
      case choose(candidates, config) do
        {:ok, resolution} -> {:ok, resolution}
        :none -> {:ok, :none}
      end
    end
  end

  defp present(:none, _intent), do: :none

  defp present(%{entity: entity, alternatives: alternatives}, intent) do
    {:ok, %{intent: intent, entity: entity, alternatives: alternatives}}
  end

  # Entities are resolved by lowercase text: `Knicks` and `knicks` share an
  # entry, and so do `weather in tokyo` and `tokyo`.
  defp cache_key(text, config) do
    if text == "" or String.length(text) > config.max_query_length do
      nil
    else
      {config.resolver, String.downcase(text)}
    end
  end

  defp cache_options(config), do: config.cache_options

  defp config(opts) do
    env = Application.fetch_env!(:knowseek, __MODULE__)

    %{
      cache: Keyword.get(opts, :cache, @cache),
      resolver: Keyword.get(opts, :resolver, Keyword.fetch!(env, :resolver)),
      supported_types: Keyword.fetch!(env, :supported_types),
      max_alternatives: Keyword.fetch!(env, :max_alternatives),
      max_query_length: Keyword.fetch!(env, :max_query_length),
      cache_options: Keyword.take(env, [:ttl, :backoff, :timeout])
    }
  end
end
