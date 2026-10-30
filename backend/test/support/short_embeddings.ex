defmodule Knowseek.Embeddings.ShortAdapter do
  @moduledoc "An embedding adapter for tests. Breaks the contract: returns one vector too few."
  @behaviour Knowseek.Embeddings

  @impl true
  def embed([_ | rest], opts) do
    {:ok, Enum.map(rest, fn _ -> List.duplicate(0.0, Keyword.fetch!(opts, :dimensions)) end)}
  end
end
