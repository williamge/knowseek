defmodule Knowseek.Embeddings do
  @moduledoc """
  Turns text into vectors for semantic search.

  The adapter is configured in `config/config.exs`:

      config :knowseek, Knowseek.Embeddings,
        adapter: Knowseek.Embeddings.Hashing,
        dimensions: 1024

  Every adapter must return vectors with exactly `dimensions/0` elements,
  because the `chunks.embedding` column has a fixed size.

  `config/runtime.exs` sets the adapter from `EMBEDDINGS_ADAPTER`:
  `hashing` (default), `ollama` (`Knowseek.Embeddings.Ollama`), or `voyage`
  (`Knowseek.Embeddings.Voyage`). Tests always use `Hashing` or stubs.
  """

  @type vector :: [float()]

  @typedoc """
  What the text is for. Some models embed a search query and the document
  that answers it differently. Adapters that do not distinguish ignore it.
  """
  @type input_type :: :document | :query

  @doc """
  Returns one vector per input text, in the same order.

  Options always include `:dimensions` and `:input_type`.
  """
  @callback embed(texts :: [String.t()], opts :: keyword()) ::
              {:ok, [vector()]} | {:error, term()}

  @doc """
  Embeds `texts` with the configured adapter.

  Options:

    * `:input_type` - `:document` (default) or `:query`.
  """
  @spec embed([String.t()], keyword()) :: {:ok, [vector()]} | {:error, term()}
  def embed(texts, opts \\ [])

  def embed([], _opts), do: {:ok, []}

  def embed(texts, opts) when is_list(texts) do
    dimensions = dimensions()
    input_type = Keyword.get(opts, :input_type, :document)
    adapter_opts = [dimensions: dimensions, input_type: input_type]

    with {:ok, vectors} <- adapter().embed(texts, adapter_opts) do
      validate(vectors, length(texts), dimensions)
    end
  end

  @spec dimensions() :: pos_integer()
  def dimensions, do: Keyword.fetch!(config(), :dimensions)

  # Enforces the adapter contract, so a bad adapter fails loudly instead of
  # silently dropping chunks (Enum.zip) or failing later in Postgres.
  defp validate(vectors, count, dimensions) do
    cond do
      length(vectors) != count ->
        {:error, {:vector_count_mismatch, expected: count, got: length(vectors)}}

      Enum.any?(vectors, &(length(&1) != dimensions)) ->
        {:error, {:dimension_mismatch, expected: dimensions}}

      true ->
        {:ok, vectors}
    end
  end

  defp adapter, do: Keyword.fetch!(config(), :adapter)

  defp config, do: Application.fetch_env!(:knowseek, __MODULE__)
end
