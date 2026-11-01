defmodule KnowseekWeb.Plugs.RateLimit do
  @moduledoc """
  Limits how often one client may call an endpoint (ADR 0023). Use it in a
  controller, for the actions that take anonymous input:

      plug KnowseekWeb.Plugs.RateLimit, [bucket: :search] when action == :create

  Every `bucket` has its own budget per client (`KnowseekWeb.ClientIp`):
  `cards`, `search` and `documents`. A client over its budget gets
  `429 Too Many Requests`, the usual error body (`{"errors": {"detail": ...}}`)
  and a `Retry-After` header with the seconds until the next token, and the
  request goes no further. Requests of another client, and of the other
  buckets, are not affected. `GET /api/health` is not limited.

  Configuration (`config :knowseek, KnowseekWeb.RateLimit`, read per request):

    * `:enabled` - `false` turns the limit off (config/test.exs does, tests
      that need it turn it on).
    * `:limits` - per bucket, `{limit, window_ms}`: a burst of `limit` requests,
      then `limit` per `window_ms` (see `Knowseek.RateLimiter`).
    * `:trusted_proxies` - CIDRs whose `X-Forwarded-For` is believed. Default
      `[]`: the client is the socket address (see `KnowseekWeb.ClientIp`).
    * `:limiter` - the `Knowseek.RateLimiter` to use. Tests inject one with
      a fake clock.
  """
  @behaviour Plug

  import Plug.Conn

  alias Knowseek.RateLimiter
  alias KnowseekWeb.ClientIp

  @type bucket :: :cards | :search | :documents

  @impl true
  def init(opts) do
    bucket = Keyword.fetch!(opts, :bucket)
    if is_atom(bucket), do: bucket, else: raise(ArgumentError, ":bucket must be an atom")
  end

  @impl true
  def call(conn, bucket) do
    config = Application.get_env(:knowseek, KnowseekWeb.RateLimit, [])

    if Keyword.get(config, :enabled, true), do: limit(conn, bucket, config), else: conn
  end

  defp limit(conn, bucket, config) do
    {limit, window_ms} = config |> Keyword.fetch!(:limits) |> Keyword.fetch!(bucket)
    client = ClientIp.key(conn, Keyword.get(config, :trusted_proxies, []))
    limiter = Keyword.get(config, :limiter, RateLimiter)

    case RateLimiter.hit(limiter, {bucket, client}, limit, window_ms) do
      :ok -> conn
      {:error, retry_after_ms} -> too_many_requests(conn, retry_after_ms)
    end
  end

  defp too_many_requests(conn, retry_after_ms) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(div(retry_after_ms + 999, 1000)))
    |> put_resp_content_type("application/json")
    |> send_resp(429, Jason.encode!(%{errors: %{detail: "Too many requests"}}))
    |> halt()
  end
end
