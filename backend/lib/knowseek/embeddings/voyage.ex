defmodule Knowseek.Embeddings.Voyage do
  @moduledoc """
  Embedding adapter for the Voyage AI embeddings API.

  Select it with `EMBEDDINGS_ADAPTER=voyage`. `config/runtime.exs` reads the
  key from `VOYAGE_API_KEY`:

      config :knowseek, Knowseek.Embeddings.Voyage,
        api_key: System.get_env("VOYAGE_API_KEY"),
        model: "voyage-3.5"

  Other options, with defaults:

    * `:base_url` - `"https://api.voyageai.com/v1"`
    * `:max_batch_size` - texts per request (`128`; the API allows 1000)
    * `:max_batch_tokens` - estimated tokens per request (`100_000`; the API
      allows 320K for `voyage-3.5`). Tokens are estimated, so keep a margin.
    * `:req_options` - extra `Req` options, for example a `Req.Test` plug

  Requests are retried on 408, 429, and 5xx responses and on transport errors,
  with exponential backoff (Req's `retry: :transient`). A failure in any batch
  fails the whole call.
  """
  @behaviour Knowseek.Embeddings

  @default_base_url "https://api.voyageai.com/v1"
  @default_model "voyage-3.5"
  @default_max_batch_size 128
  @default_max_batch_tokens 100_000

  @impl true
  def embed(texts, opts) do
    config = Application.get_env(:knowseek, __MODULE__, [])

    case Keyword.get(config, :api_key) do
      key when key in [nil, ""] ->
        {:error, {:voyage, :missing_api_key}}

      key ->
        req = new_request(key, config)
        body = request_body(config, opts)

        texts
        |> batches(config)
        |> embed_batches(req, body)
    end
  end

  @doc false
  # Public for tests. Splits texts into batches that respect the size and
  # estimated token limits. A text over the token limit gets its own batch;
  # the API truncates it.
  @spec batches([String.t()], keyword()) :: [[String.t()]]
  def batches(texts, config) do
    max_size = Keyword.get(config, :max_batch_size, @default_max_batch_size)
    max_tokens = Keyword.get(config, :max_batch_tokens, @default_max_batch_tokens)

    texts
    |> Enum.chunk_while(
      {[], 0, 0},
      fn text, {batch, size, tokens} ->
        text_tokens = estimate_tokens(text)

        if batch != [] and (size + 1 > max_size or tokens + text_tokens > max_tokens) do
          {:cont, Enum.reverse(batch), {[text], 1, text_tokens}}
        else
          {:cont, {[text | batch], size + 1, tokens + text_tokens}}
        end
      end,
      fn
        {[], _, _} -> {:cont, {[], 0, 0}}
        {batch, _, _} -> {:cont, Enum.reverse(batch), {[], 0, 0}}
      end
    )
  end

  # Voyage averages about 4 characters per token for English. Bytes / 3 is
  # a conservative estimate that also covers multi-byte scripts.
  defp estimate_tokens(text), do: div(byte_size(text), 3) + 1

  defp new_request(api_key, config) do
    [
      base_url: Keyword.get(config, :base_url, @default_base_url),
      auth: {:bearer, api_key},
      retry: :transient
    ]
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Req.new()
  end

  defp request_body(config, opts) do
    %{
      model: Keyword.get(config, :model, @default_model),
      input_type: Atom.to_string(Keyword.fetch!(opts, :input_type)),
      output_dimension: Keyword.fetch!(opts, :dimensions)
    }
  end

  defp embed_batches(batches, req, body) do
    Enum.reduce_while(batches, {:ok, []}, fn batch, {:ok, acc} ->
      case embed_batch(req, Map.put(body, :input, batch)) do
        {:ok, vectors} -> {:cont, {:ok, [vectors | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, acc |> Enum.reverse() |> Enum.concat()}
      error -> error
    end
  end

  defp embed_batch(req, body) do
    case Req.post(req, url: "/embeddings", json: body) do
      {:ok, %Req.Response{status: 200, body: %{"data" => data}}} when is_list(data) ->
        parse_data(data, length(body.input))

      {:ok, %Req.Response{status: 200}} ->
        {:error, {:voyage, :unexpected_response}}

      {:ok, %Req.Response{status: status, body: response_body}} ->
        {:error, {:voyage, status, error_detail(response_body)}}

      {:error, exception} ->
        {:error, {:voyage, exception}}
    end
  end

  # The API returns `index` for each item. Sort by it instead of trusting order.
  defp parse_data(data, expected) do
    vectors =
      data
      |> Enum.sort_by(& &1["index"])
      |> Enum.map(& &1["embedding"])

    if length(vectors) == expected and Enum.all?(vectors, &is_list/1) do
      {:ok, vectors}
    else
      {:error, {:voyage, :unexpected_response}}
    end
  end

  defp error_detail(%{"detail" => detail}), do: detail
  defp error_detail(_body), do: nil
end
