defmodule Knowseek.Cards do
  @moduledoc """
  Live fact cards for an entity (ADR 0017, decision 4): the score of a team,
  later the filings of a company and the weather of a place.

  `get/2` is cache-only, like `Knowseek.Entities.resolve/2`. It never calls a
  provider in the caller's process. It reads the in-memory cache of
  `Knowseek.Cache` and, when the card is missing or past its TTL, asks the
  cache to refresh it in a supervised task (one fetch per entity, however many
  callers; a short timeout; a backoff after a failure; at most `:max_in_flight`
  fetches at once; and a stop of all fetches while an upstream rate limit
  lasts). The caller polls. Nothing writes to the database.

  Which provider handles an entity is config (`:providers`, in order, the
  first whose `c:Knowseek.Cards.Provider.handles?/1` is true wins). Providers
  implement `Knowseek.Cards.Provider`. A provider that defines
  `c:Knowseek.Cards.Provider.intent/0` (the weather provider) is skipped unless
  the query carried that intent (`:intent` option, from
  `Knowseek.Entities.resolve/2`); the others ignore the intent (ADR 0022).

  ## Result

  `:none` when no provider handles the entity (callers show no card), else a
  map:

    * `status` - `:fresh` (within its TTL), `:stale` (past its TTL, kept while
      the refresh runs or after it failed), `:pending` (nothing cached yet, a
      fetch was started), `:unavailable` (the fetch failed and nothing was ever
      cached).
    * `type`, `title`, `facts` - the card (`Knowseek.Cards.Provider`), or `nil`
      for `:pending` and `:unavailable`.
    * `as_of` - when the data was fetched (UTC), or `nil`.
    * `refresh_after_ms` - when to ask again: the time the card has left,
      clamped to 2-60 s, or 2 s for `:stale` (the refresh that runs finishes
      in a second or two; a failed one is retried after the backoff) and 30 s
      for `:unavailable`;
      0.7 s for `:pending`.

  ## One cache per provider

  Each provider has its own `Knowseek.Cache` instance (`cache_name/1`, started
  by the application for every provider in `:providers`), because a rate limit
  stops every fetch of a cache: a 429 from Open-Meteo must not make the NBA
  cards `unavailable`, and the entries and in-flight slots that a flood of
  places uses must not push out the team cards. Adding a provider to the list
  gives it a cache.

  ## Configuration

  See `config/config.exs`: `providers`, `backoff`, `timeout`, `cache` (start
  options of every provider's cache) and `caches` (options per provider, merged
  over `cache`).
  """

  alias Knowseek.Cache
  alias Knowseek.Entities.Entity

  @pending_poll_ms 700
  @stale_poll_ms 2_000
  @unavailable_poll_ms 30_000
  @min_poll_ms 2_000
  @max_poll_ms 60_000

  @type status :: :fresh | :stale | :pending | :unavailable
  @type t :: %{
          status: status(),
          type: String.t() | nil,
          title: String.t() | nil,
          facts: map() | nil,
          as_of: DateTime.t() | nil,
          refresh_after_ms: pos_integer()
        }

  @doc """
  The card for `entity`, or `:none`. Options (for tests): `:cache` (a started
  `Knowseek.Cache` name for every provider, or a map of provider to cache
  name), `:providers`, `:clock` (a function returning the
  time in milliseconds, the one the cache uses), and `:intent` (the intent of
  the query, `nil` when it had none).
  """
  @spec get(Entity.t(), keyword()) :: t() | :none
  def get(%Entity{} = entity, opts \\ []) do
    config = config(opts)

    case provider(entity, config) do
      nil -> :none
      provider -> read(provider, entity, config)
    end
  end

  @doc """
  The name of the cache of `provider` (`Knowseek.Cards.Cache.<last part of the
  module name>`), started by `Knowseek.Application`.
  """
  @spec cache_name(module()) :: atom()
  def cache_name(provider) when is_atom(provider) do
    Module.concat(Knowseek.Cards.Cache, provider |> Module.split() |> List.last())
  end

  @doc """
  The start options of the cache of `provider`: config `cache`, with the
  provider's entry of `caches` merged over it.
  """
  @spec cache_options(module()) :: keyword()
  def cache_options(provider) when is_atom(provider) do
    env = Application.fetch_env!(:knowseek, __MODULE__)

    Keyword.merge(
      Keyword.get(env, :cache, []),
      env |> Keyword.get(:caches, []) |> Keyword.get(provider, [])
    )
  end

  @doc """
  Blocks until the fetch running for `entity` (if any) has finished. For
  tests and scripts that need the result of a `:pending`; the request path
  never calls it. Same options as `get/2`.
  """
  @spec await(Entity.t(), keyword()) :: :ok
  def await(%Entity{} = entity, opts \\ []) do
    config = config(opts)

    case provider(entity, config) do
      nil ->
        :ok

      provider ->
        Cache.await(
          cache(config, provider),
          key(provider, entity),
          Keyword.get(opts, :timeout, :infinity)
        )
    end
  end

  defp provider(entity, config) do
    Enum.find(config.providers, &(intent_matches?(&1, config.intent) and &1.handles?(entity)))
  end

  defp intent_matches?(provider, intent) do
    not (Code.ensure_loaded?(provider) and function_exported?(provider, :intent, 0)) or
      provider.intent() == intent
  end

  defp cache(%{cache: nil}, provider), do: cache_name(provider)

  defp cache(%{cache: %{} = caches}, provider),
    do: Map.get_lazy(caches, provider, fn -> cache_name(provider) end)

  defp cache(%{cache: name}, _provider), do: name

  defp key(provider, entity), do: {provider, entity.id}

  defp read(provider, entity, config) do
    result =
      Cache.get(
        cache(config, provider),
        key(provider, entity),
        fn -> fetch(provider, entity) end,
        ttl: fn {_card, ttl} -> ttl end,
        backoff: config.backoff,
        timeout: config.timeout
      )

    present(result, config)
  end

  # Runs in the cache's task, never in the caller. The TTL is stored with the
  # card, so that the cache can read it from the value.
  defp fetch(provider, entity) do
    case provider.fetch(entity) do
      {:ok, %{type: _, title: _, facts: _} = card, ttl} when is_integer(ttl) -> {:ok, {card, ttl}}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:bad_provider_return, other}}
    end
  end

  defp present({status, {card, ttl}, as_of}, config) when status in [:fresh, :stale] do
    refresh_after =
      if status == :fresh do
        remaining = DateTime.diff(as_of, now(config), :millisecond) + ttl
        remaining |> max(@min_poll_ms) |> min(@max_poll_ms)
      else
        @stale_poll_ms
      end

    Map.merge(card, %{status: status, as_of: as_of, refresh_after_ms: refresh_after})
  end

  defp present(:pending, _config), do: empty(:pending, @pending_poll_ms)
  defp present({:unavailable, _reason}, _config), do: empty(:unavailable, @unavailable_poll_ms)

  defp empty(status, refresh_after_ms) do
    %{
      status: status,
      type: nil,
      title: nil,
      facts: nil,
      as_of: nil,
      refresh_after_ms: refresh_after_ms
    }
  end

  defp now(config) do
    DateTime.from_unix!(config.clock.(), :millisecond)
  end

  defp config(opts) do
    env = Application.fetch_env!(:knowseek, __MODULE__)

    %{
      cache: Keyword.get(opts, :cache),
      providers: Keyword.get(opts, :providers, Keyword.fetch!(env, :providers)),
      backoff: Keyword.fetch!(env, :backoff),
      timeout: Keyword.fetch!(env, :timeout),
      intent: Keyword.get(opts, :intent),
      clock: Keyword.get(opts, :clock, fn -> System.system_time(:millisecond) end)
    }
  end
end
