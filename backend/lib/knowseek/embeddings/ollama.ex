defmodule Knowseek.Embeddings.Ollama do
  @moduledoc """
  Embedding adapter for a local Ollama server. Free, and no API key.

  Install and start Ollama natively (`brew install ollama`, then
  `brew services start ollama`) so it uses the GPU. `make ollama` pulls the
  model. Select the adapter with `EMBEDDINGS_ADAPTER=ollama`.

      config :knowseek, Knowseek.Embeddings.Ollama,
        base_url: "http://localhost:11434",
        model: "bge-m3"

  The model must output `Knowseek.Embeddings.dimensions/0` values (1024).
  `bge-m3` does, and it needs no query or document prefix, so `:input_type`
  is ignored.

  Other options, with defaults:

    * `:max_batch_size` - texts per request (`32`)
    * `:req_options` - extra `Req` options, for example a `Req.Test` plug

  `:document` requests are retried on 408, 429, and 5xx responses and on
  transport errors (Req's `retry: :transient`). The first request after a
  start loads the model, so their receive timeout is long (120 s).

  `:query` requests wait for a user, so they have no retries and a 10 s
  limit (`Knowseek.Embeddings.query_request_options/0`). Every request sets
  `keep_alive` so the model stays loaded and the first query is fast.
  """
  @behaviour Knowseek.Embeddings

  alias Knowseek.Embeddings

  @default_base_url "http://localhost:11434"
  @default_model "bge-m3"
  @default_max_batch_size 32
  @keep_alive "24h"

  @impl true
  def embed(texts, opts) do
    config = Application.get_env(:knowseek, __MODULE__, [])
    req = new_request(config, Keyword.fetch!(opts, :input_type))
    model = Keyword.get(config, :model, @default_model)

    texts
    |> Enum.chunk_every(Keyword.get(config, :max_batch_size, @default_max_batch_size))
    |> Embeddings.embed_batches(&embed_batch(req, model, &1))
  end

  defp new_request(config, input_type) do
    [base_url: Keyword.get(config, :base_url, @default_base_url)]
    |> Keyword.merge(limits(input_type))
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Req.new()
  end

  defp limits(:query), do: Embeddings.query_request_options()
  defp limits(:document), do: [retry: :transient, receive_timeout: 120_000]

  defp embed_batch(req, model, batch) do
    body = %{model: model, input: batch, truncate: true, keep_alive: @keep_alive}

    case Req.post(req, url: "/api/embed", json: body) do
      {:ok, %Req.Response{status: 200, body: %{"embeddings" => vectors}}}
      when is_list(vectors) and length(vectors) == length(batch) ->
        {:ok, vectors}

      {:ok, %Req.Response{status: 200}} ->
        {:error, {:ollama, :unexpected_response}}

      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:error, {:ollama, status, error_detail(response_body)}}

      {:error, exception} ->
        {:error, {:ollama, exception}}
    end
  end

  defp error_detail(%{"error" => detail}), do: detail
  defp error_detail(_body), do: nil
end
