defmodule Knowseek.Download do
  @moduledoc """
  What an HTTP response cost on the wire, for the network budget (#90, ADR
  0034): the response headers and the body as received (still compressed).
  Request bytes and TLS are not counted.

  `measure/2` adds a Req response step that runs before `retry` and
  `decompress_body`, so it sees every attempt and the compressed body.
  `count/2` is `measure/2` with the configured sink (`config :knowseek,
  Knowseek.Download, sink: {module, function}`), for clients that run outside
  a discovery job. A discovery source uses `measure/2` with the `:on_bytes`
  function `Knowseek.Discovery` gives it: a source never writes (rule 3).
  """

  @doc """
  The size of `response` in bytes: each header line (`name: value` and the
  line break) plus the body as received. A body that is not a binary counts 0.
  """
  @spec size(Req.Response.t()) :: non_neg_integer()
  def size(%Req.Response{headers: headers, body: body}) do
    header_bytes =
      Enum.reduce(headers, 0, fn {name, values}, total ->
        Enum.reduce(List.wrap(values), total, fn value, acc ->
          acc + byte_size(name) + byte_size(value) + 4
        end)
      end)

    if is_binary(body), do: header_bytes + byte_size(body), else: header_bytes
  end

  @doc """
  Adds a response step to `request` that calls `fun` with `size/1` of every
  response. `nil` leaves the request as it is.
  """
  @spec measure(Req.Request.t(), (non_neg_integer() -> any()) | nil) :: Req.Request.t()
  def measure(request, nil), do: request

  def measure(request, fun) when is_function(fun, 1) do
    Req.Request.prepend_response_steps(request,
      download: fn {request, response} ->
        fun.(size(response))
        {request, response}
      end
    )
  end

  @doc """
  Counts every response of `request` for `source` through the configured
  sink. No sink: the request as it is.
  """
  @spec count(Req.Request.t(), String.t()) :: Req.Request.t()
  def count(request, source) do
    case Application.get_env(:knowseek, __MODULE__, [])[:sink] do
      {module, function} -> measure(request, &apply(module, function, [source, &1]))
      nil -> request
    end
  end
end
