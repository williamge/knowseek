defmodule KnowseekWeb.Plugs.RateLimit do
  @moduledoc """
  Limits how often one client may call the endpoints that take anonymous input
  (ADR 0023). It is a plug of `KnowseekWeb.Endpoint`, **before**
  `Plug.Parsers`: a client over its limit is answered before the server reads
  and decodes its request body.

  Routes, and the budget (`bucket`) each one draws on, per client
  (`KnowseekWeb.ClientIp`):

    * `GET` and `HEAD /api/cards` - `cards` (`HEAD` runs the controller as a
      `GET`, so it is limited too)
    * `POST /api/search` - `search`
    * `POST /api/documents` - `documents`

  Nothing else is limited: `GET /api/health` (probes), the reads of
  `/api/documents` (the UI polls them), and every other path. A client over
  its budget gets `429 Too Many Requests`, the usual error body
  (`{"errors": {"detail": ...}}`) and a `Retry-After` header with the seconds
  until the next token, and the request goes no further. Requests of another
  client, and of the other buckets, are not affected.

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
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case bucket(conn) do
      nil -> conn
      bucket -> limit(conn, bucket, Application.get_env(:knowseek, KnowseekWeb.RateLimit, []))
    end
  end

  @doc "The bucket a request draws on, or `nil` when the route is not limited."
  @spec bucket(Plug.Conn.t()) :: bucket() | nil
  def bucket(%Plug.Conn{method: method, path_info: ["api", "cards"]})
      when method in ["GET", "HEAD"],
      do: :cards

  def bucket(%Plug.Conn{method: "POST", path_info: ["api", "search"]}), do: :search
  def bucket(%Plug.Conn{method: "POST", path_info: ["api", "documents"]}), do: :documents
  def bucket(_conn), do: nil

  defp limit(conn, bucket, config) do
    if Keyword.get(config, :enabled, true) do
      {limit, window_ms} = config |> Keyword.fetch!(:limits) |> Keyword.fetch!(bucket)
      cidrs = config |> Keyword.get(:trusted_proxies, []) |> ClientIp.cidrs!()
      client = ClientIp.key(conn, cidrs)
      limiter = Keyword.get(config, :limiter, RateLimiter)

      case RateLimiter.hit(limiter, {bucket, client}, limit, window_ms) do
        :ok -> conn
        {:error, retry_after_ms} -> too_many_requests(conn, retry_after_ms)
      end
    else
      conn
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
