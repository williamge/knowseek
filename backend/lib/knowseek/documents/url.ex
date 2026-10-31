defmodule Knowseek.Documents.URL do
  @moduledoc """
  Canonical form of a document URL, so that variants of one page share one
  document.

  For `http` and `https` URLs, `canonicalize/1`:

  - lowercases the scheme and the host,
  - drops the fragment,
  - drops the default port (80 for `http`, 443 for `https`),
  - gives an empty path the path `/`,
  - drops tracking parameters (see `tracking_param?/1`),
  - sorts the remaining query parameters, and drops an empty query.

  Parameter names and values are kept byte for byte, so the result never
  changes what the server sees. Any other URL (`urn:`, `ftp:`, text that does
  not parse) is only trimmed.
  """

  # Exact parameter names, lowercase. Edit this list to add a tracker.
  @tracking_params ~w(
    fbclid gclid dclid gbraid wbraid msclkid yclid twclid igshid
    mc_cid mc_eid mkt_tok _hsenc _hsmi
  )
  # Parameter name prefixes, lowercase.
  @tracking_prefixes ~w(utm_)

  @doc "Returns the canonical form of `url`. See the module doc for the rules."
  @spec canonicalize(String.t()) :: String.t()
  def canonicalize(url) when is_binary(url) do
    url = String.trim(url)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri
      when is_binary(scheme) and is_binary(host) and host != "" ->
        scheme = String.downcase(scheme)

        if scheme in ["http", "https"] do
          uri |> canonical_uri(scheme) |> URI.to_string()
        else
          url
        end

      _ ->
        url
    end
  end

  @doc "True when the query parameter `name` only tracks where a visitor came from."
  @spec tracking_param?(String.t()) :: boolean()
  def tracking_param?(name) do
    name = name |> URI.decode_www_form() |> String.downcase()
    name in @tracking_params or String.starts_with?(name, @tracking_prefixes)
  end

  defp canonical_uri(%URI{} = uri, scheme) do
    %URI{
      uri
      | scheme: scheme,
        host: String.downcase(uri.host),
        port: if(uri.port == URI.default_port(scheme), do: nil, else: uri.port),
        path: if(uri.path in [nil, ""], do: "/", else: uri.path),
        query: canonical_query(uri.query),
        fragment: nil
    }
  end

  defp canonical_query(nil), do: nil

  defp canonical_query(query) do
    query
    |> String.split("&", trim: true)
    |> Enum.reject(&tracking_param?(&1 |> String.split("=", parts: 2) |> hd()))
    |> Enum.sort()
    |> case do
      [] -> nil
      params -> Enum.join(params, "&")
    end
  end
end
