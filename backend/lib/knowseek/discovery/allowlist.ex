defmodule Knowseek.Discovery.Allowlist do
  @moduledoc """
  The hosts a crawler may fetch from (`allowed_hosts` in the
  `Knowseek.Discovery` config; #88, ADR 0032) and the form in which a link to
  any other host is logged. Pure; internal to the `Knowseek.Discovery` context.

  Matching is on the exact host, after lowercasing and dropping a leading
  `www.`: `en.m.wikipedia.org` is not `en.wikipedia.org`.
  """

  # The log is not a place for megabyte URLs.
  @max_url_bytes 2_000

  @doc "The allowed hosts from config, normalized like `host/1`."
  @spec hosts() :: [String.t()]
  def hosts do
    :knowseek
    |> Application.get_env(Knowseek.Discovery, [])
    |> Keyword.get(:allowed_hosts, [])
    |> Enum.map(&host/1)
  end

  @doc "A web link in the form the log stores, or `:error` when `url` is not a web link."
  @spec parse(String.t()) :: {:ok, %{url: String.t(), host: String.t()}} | :error
  def parse(url) when is_binary(url) do
    url = url |> String.trim() |> protocol_relative()

    with %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) <-
           URI.parse(url),
         scheme when scheme in ["http", "https"] <- String.downcase(scheme),
         true <- host != "",
         stored =
           to_string(%URI{uri | scheme: scheme, host: String.downcase(host), fragment: nil}),
         true <- byte_size(stored) <= @max_url_bytes do
      {:ok, %{url: stored, host: host(host)}}
    else
      _not_a_web_link -> :error
    end
  end

  def parse(_url), do: :error

  @doc "Whether `url` is a web link to a host on the allowlist."
  @spec allowed?(String.t()) :: boolean()
  def allowed?(url) do
    case parse(url) do
      {:ok, %{host: host}} -> host in hosts()
      :error -> false
    end
  end

  defp protocol_relative("//" <> _rest = url), do: "https:" <> url
  defp protocol_relative(url), do: url

  # Lowercase, without a leading "www.".
  defp host(host) do
    case String.downcase(host) do
      "www." <> rest when rest != "" -> rest
      host -> host
    end
  end
end
