defmodule Knowseek.Embeddings do
  @moduledoc """
  Turns text into vectors for semantic search.

  The adapter is configured in `config/config.exs`:

      config :knowseek, Knowseek.Embeddings,
        adapter: Knowseek.Embeddings.Hashing,
        dimensions: 1024

  Every adapter must return vectors with exactly `dimensions/0` elements,
  because the `chunks.embedding` column has a fixed size.
  """

  @type vector :: [float()]

  @doc "Returns one vector per input text, in the same order."
  @callback embed(texts :: [String.t()], opts :: keyword()) ::
              {:ok, [vector()]} | {:error, term()}

  @spec embed([String.t()]) :: {:ok, [vector()]} | {:error, term()}
  def embed([]), do: {:ok, []}

  def embed(texts) when is_list(texts) do
    adapter().embed(texts, dimensions: dimensions())
  end

  @spec dimensions() :: pos_integer()
  def dimensions, do: Keyword.fetch!(config(), :dimensions)

  defp adapter, do: Keyword.fetch!(config(), :adapter)

  defp config, do: Application.fetch_env!(:knowseek, __MODULE__)
end
