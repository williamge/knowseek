defmodule Knowseek.Embeddings.Hashing do
  @moduledoc """
  A local, deterministic embedding adapter based on feature hashing.

  Each lowercase word token is hashed into one of `dimensions` buckets, and
  the result is L2-normalized. Texts that share words get similar vectors.
  It has no notion of meaning, so it is only a stand-in for dev and test
  until a real model adapter exists.
  """
  @behaviour Knowseek.Embeddings

  @impl true
  def embed(texts, opts) do
    dimensions = Keyword.fetch!(opts, :dimensions)
    {:ok, Enum.map(texts, &embed_one(&1, dimensions))}
  end

  defp embed_one(text, dimensions) do
    counts =
      text
      |> String.downcase()
      |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
      |> Enum.frequencies_by(&:erlang.phash2(&1, dimensions))

    norm = counts |> Map.values() |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt()

    if norm == 0.0 do
      # pgvector cannot compute cosine distance for a zero vector.
      [1.0 | List.duplicate(0.0, dimensions - 1)]
    else
      for i <- 0..(dimensions - 1), do: Map.get(counts, i, 0) / norm
    end
  end
end
