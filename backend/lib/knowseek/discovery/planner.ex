defmodule Knowseek.Discovery.Planner do
  @moduledoc """
  Turns a user query into a few focused search queries before discovery calls
  its sources (task 007, ADR 0025).

  A planner is a behaviour. The adapter is configured in `config/config.exs`
  and `config/runtime.exs` sets it from `PLANNER_ADAPTER`:

      config :knowseek, Knowseek.Discovery.Planner,
        adapter: Knowseek.Discovery.Planner.Passthrough,
        max_planned: 3,
        max_query_length: 100

    * `Knowseek.Discovery.Planner.Passthrough` - returns the query as it is.
      The default, and the adapter in tests.
    * `Knowseek.Discovery.Planner.Ollama` - a local LLM through Ollama.

  The query is untrusted text, and a planner's output is only ever used as
  search strings: no planner gets tools, and nothing it returns is run, stored,
  or shown as an instruction. `resolve/2` is the one place that enforces this
  for every adapter:

    * the original query is always the first search, so planning only adds;
    * every other query is cleaned (`clean/2`): control characters removed,
      whitespace collapsed, cut to `max_query_length` characters, empty ones
      dropped, duplicates (ignoring case and spacing) dropped, at most
      `max_planned` kept;
    * a planner that fails, raises, or returns nonsense never fails discovery:
      the result is the original query alone and `{:fallback, reason}`.
  """
  require Logger

  @typedoc """
  `:ok` - the planner planned. `:passthrough` - the passthrough adapter ran.
  `{:fallback, reason}` - the planner failed, the original query alone is used.
  """
  @type status :: :ok | :passthrough | {:fallback, term()}

  @type result :: %{queries: [String.t(), ...], status: status()}

  @doc """
  Returns the search queries for `query`. The adapter may return the original
  among them; `resolve/2` puts it first and removes the duplicate.
  """
  @callback plan(query :: String.t(), opts :: keyword()) ::
              {:ok, [String.t()]} | {:error, term()}

  @defaults [
    adapter: Knowseek.Discovery.Planner.Passthrough,
    max_planned: 3,
    max_query_length: 100
  ]

  @doc """
  Plans `query` with the configured adapter (or `opts[:planner]`).

  Never fails. Returns `%{queries: [original | planned], status: status}`.
  """
  @spec resolve(String.t(), keyword()) :: result()
  def resolve(query, opts \\ []) when is_binary(query) do
    adapter = Keyword.get(opts, :planner) || config(:adapter)

    case call(adapter, query, opts) do
      {:ok, planned} when is_list(planned) ->
        %{queries: [query | clean(planned, query)], status: ok_status(adapter)}

      {:ok, other} ->
        fallback(query, {:invalid_plan, other})

      {:error, reason} ->
        fallback(query, reason)

      other ->
        fallback(query, {:invalid_plan, other})
    end
  end

  @doc """
  Cleans planned queries, an untrusted list. Elements that are not strings are
  dropped. Returns at most `max_planned` strings, none empty, none equal to
  `original` or to another one when case and spacing are ignored.
  """
  @spec clean([term()], String.t()) :: [String.t()]
  def clean(planned, original) when is_list(planned) do
    max_length = config(:max_query_length)

    planned
    |> Enum.filter(&(is_binary(&1) and String.valid?(&1)))
    |> Stream.map(&sanitize(&1, max_length))
    |> Stream.reject(&(&1 == ""))
    |> Enum.reduce_while({[], MapSet.new([fold(original)])}, fn query, {kept, seen} ->
      cond do
        length(kept) >= config(:max_planned) -> {:halt, {kept, seen}}
        MapSet.member?(seen, fold(query)) -> {:cont, {kept, seen}}
        true -> {:cont, {[query | kept], MapSet.put(seen, fold(query))}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @doc "Reads one planner option from config."
  @spec config(atom()) :: term()
  def config(key) do
    @defaults
    |> Keyword.merge(Application.get_env(:knowseek, __MODULE__, []))
    |> Keyword.fetch!(key)
  end

  defp call(adapter, query, opts) do
    adapter.plan(query, opts)
  rescue
    exception -> {:error, {:exception, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp ok_status(Knowseek.Discovery.Planner.Passthrough), do: :passthrough
  defp ok_status(_adapter), do: :ok

  defp fallback(query, reason) do
    Logger.warning(
      "discovery planner failed, searching the original query only: #{inspect(reason)}"
    )

    %{queries: [query], status: {:fallback, reason}}
  end

  # Control and format characters (newlines, escapes, bidi marks, zero-width
  # spaces) become spaces; then whitespace collapses, and the text is cut.
  defp sanitize(text, max_length) do
    text
    |> String.replace(~r/[\p{Cc}\p{Cf}]/u, " ")
    |> String.split()
    |> Enum.join(" ")
    |> String.slice(0, max_length)
    |> String.trim()
  end

  defp fold(text), do: text |> String.downcase() |> String.split() |> Enum.join(" ")
end
