defmodule Knowseek.Embeddings do
  @moduledoc """
  Turns text into vectors for semantic search.

  The adapter is configured in `config/config.exs`:

      config :knowseek, Knowseek.Embeddings,
        adapter: Knowseek.Embeddings.Ollama,
        dimensions: 1024

  Every adapter must return vectors with exactly `dimensions/0` elements,
  because the `chunk_vectors.embedding` column has a fixed size.

  Every adapter also says which model it embeds with (`model/0`, a callback).
  `Knowseek.Documents` records it with the vectors it stores, so a change of
  model is noticed and the stored passages are embedded again (ADR 0035).
  `Knowseek.Embeddings` itself stays free of the database.

  `config/runtime.exs` sets the adapter from `EMBEDDINGS_ADAPTER`:
  `ollama` (`Knowseek.Embeddings.Ollama`, the default, ADR 0016), `hashing`
  (`Knowseek.Embeddings.Hashing`, the opt-out), or `voyage`
  (`Knowseek.Embeddings.Voyage`). Tests always use `Hashing` or stubs.
  """

  @type vector :: [float()]

  @typedoc """
  What the text is for. Some models embed a search query and the document
  that answers it differently. Adapters that do not distinguish ignore it.
  """
  @type input_type :: :document | :query

  @typedoc "Which model the adapter embeds with. `digest` is \"\" when the provider has none."
  @type model :: %{name: String.t(), digest: String.t(), dimensions: pos_integer()}

  @input_types [:document, :query]
  @model_key {__MODULE__, :model}

  @doc """
  Returns one vector per input text, in the same order.

  Options always include `:dimensions` and `:input_type`.
  """
  @callback embed(texts :: [String.t()], opts :: keyword()) ::
              {:ok, [vector()]} | {:error, term()}

  @doc "The provider and model the adapter embeds with, and the model's digest (\"\" if none)."
  @callback model() :: {:ok, %{name: String.t(), digest: String.t()}} | {:error, term()}

  @doc """
  Embeds `texts` with the configured adapter.

  Options:

    * `:input_type` - `:document` (default) or `:query`. Any other value
      returns `{:error, {:invalid_input_type, value}}`.
  """
  @spec embed([String.t()], keyword()) :: {:ok, [vector()]} | {:error, term()}
  def embed(texts, opts \\ []) when is_list(texts) do
    case Keyword.get(opts, :input_type, :document) do
      input_type when input_type in @input_types -> embed_texts(texts, input_type)
      other -> {:error, {:invalid_input_type, other}}
    end
  end

  defp embed_texts([], _input_type), do: {:ok, []}

  defp embed_texts(texts, input_type) do
    dimensions = dimensions()
    adapter_opts = [dimensions: dimensions, input_type: input_type]

    with {:ok, vectors} <- adapter().embed(texts, adapter_opts) do
      validate(vectors, length(texts), dimensions)
    end
  end

  @doc """
  For adapters: calls `fun` on each batch in order and concatenates the
  vectors. Stops at the first `{:error, _}` and returns it.
  """
  @spec embed_batches([[String.t()]], ([String.t()] -> {:ok, [vector()]} | {:error, term()})) ::
          {:ok, [vector()]} | {:error, term()}
  def embed_batches(batches, fun) do
    batches
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, acc} ->
      case fun.(batch) do
        {:ok, vectors} -> {:cont, {:ok, [vectors | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, acc |> Enum.reverse() |> Enum.concat()}
      error -> error
    end
  end

  @doc """
  For adapters: `Req` options for a `:query` call. A user waits for a query
  embedding in the request path, so the call gets a short time limit and no
  retries. Total worst case: 2 s to connect plus 10 s for the response.
  """
  @spec query_request_options() :: keyword()
  def query_request_options do
    [retry: false, connect_options: [timeout: 2_000], receive_timeout: 10_000]
  end

  @doc """
  The model of the configured adapter, from memory. Asks the adapter only when
  nothing is remembered for it (the first call, or after the adapter changed).
  """
  @spec model() :: {:ok, model()} | {:error, term()}
  def model do
    adapter = adapter()

    case :persistent_term.get(@model_key, nil) do
      {^adapter, model} -> {:ok, model}
      _ -> refresh_model()
    end
  end

  @doc """
  Asks the adapter which model it serves now and remembers the answer. An error
  leaves what is remembered.
  """
  @spec refresh_model() :: {:ok, model()} | {:error, term()}
  def refresh_model do
    adapter = adapter()

    with {:ok, %{name: name, digest: digest}} <- adapter.model() do
      model = %{name: name, digest: digest, dimensions: dimensions()}
      remember = {adapter, model}

      # A write to :persistent_term is costly (a global GC), so only a change is written.
      if :persistent_term.get(@model_key, nil) != remember,
        do: :persistent_term.put(@model_key, remember)

      {:ok, model}
    end
  end

  @spec dimensions() :: pos_integer()
  def dimensions, do: Keyword.fetch!(config(), :dimensions)

  # Enforces the adapter contract, so a bad adapter fails loudly instead of
  # silently dropping chunks (Enum.zip) or failing later in the database.
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
