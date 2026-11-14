defmodule Knowseek.Embeddings.HookAdapter do
  @moduledoc """
  An embedding adapter for tests: Hashing, with a hook. `config :knowseek,
  Knowseek.Embeddings.HookAdapter, hook: fun` calls `fun.(texts)` before each
  `embed/2`; `{:error, reason}` from the hook is the adapter's answer, anything
  else lets Hashing embed. It says it is `hashing/<version>` too.
  """
  @behaviour Knowseek.Embeddings

  alias Knowseek.Embeddings.Hashing

  @impl true
  def model, do: Hashing.model()

  @impl true
  def embed(texts, opts) do
    hook = Application.get_env(:knowseek, __MODULE__, [])[:hook]

    case hook && hook.(texts) do
      {:error, _} = error -> error
      _ -> Hashing.embed(texts, opts)
    end
  end
end
