defmodule KnowseekWeb.ClientIp do
  @moduledoc """
  Who a request comes from, for rate limiting (ADR 0023).

  The client is the **socket's remote address**. A client cannot choose it,
  and no header changes it. `X-Forwarded-For` is read only when the socket
  address belongs to a **trusted proxy**: a CIDR in `:trusted_proxies` of
  `KnowseekWeb.RateLimit` (default `[]`: never). It is then read from the
  right: each proxy appends the address it saw, so the entries on the left
  were written by the client and are worth nothing. The client is the
  rightmost entry that is not itself a trusted proxy. When the header is
  missing or its rightmost entry is not a bare address (junk, or an address
  with a port such as `203.0.113.9:4711`, which some proxies append), the
  client is the proxy: every such request shares the proxy's bucket. That
  fails closed (the limit is stricter, never looser), and the log does not
  say so, so a proxy that adds ports needs to be set up to send plain
  addresses.

  The key is the address, with two normalizations: an IPv4-mapped IPv6
  address (`::ffff:192.0.2.1`, what a dual-stack listener reports for an IPv4
  client) is the IPv4 address, and an IPv6 address is its /64 prefix, because
  one subscriber usually owns a whole /64 and could otherwise get a fresh
  bucket per address.
  """

  import Bitwise

  @type cidr :: {:inet.ip_address(), 0..128}
  @type key :: :inet.ip4_address() | {:ip6_64, 0..65_535, 0..65_535, 0..65_535, 0..65_535}

  @doc """
  The rate-limit key of `conn`. `cidrs` are the parsed trusted proxies from
  `parse_cidrs!/1` or `cidrs!/1`.
  """
  @spec key(Plug.Conn.t(), [cidr()]) :: key()
  def key(%Plug.Conn{remote_ip: remote_ip} = conn, cidrs \\ []) do
    remote = unmap(remote_ip)

    client =
      if cidrs != [] and trusted?(remote, cidrs),
        do: forwarded_client(conn, cidrs) || remote,
        else: remote

    prefix(client)
  end

  @doc """
  Parses `"10.0.0.0/8"`, `"fd00::/8"` and bare addresses (`"127.0.0.1"` is
  `/32`). Raises `ArgumentError` on anything else, so that a typo in the
  configuration stops the application instead of silently trusting nothing
  (or everything).
  """
  @spec parse_cidrs!([String.t() | cidr()]) :: [cidr()]
  def parse_cidrs!(list), do: Enum.map(list, &parse_cidr!/1)

  @doc """
  `parse_cidrs!/1`, parsed once per distinct list: the result is kept in
  `:persistent_term`, so a request does not parse the configuration again.
  The application calls it at start, so an invalid entry stops the start.
  """
  @spec cidrs!([String.t() | cidr()]) :: [cidr()]
  def cidrs!(list) do
    case :persistent_term.get({__MODULE__, list}, nil) do
      nil ->
        cidrs = parse_cidrs!(list)
        :persistent_term.put({__MODULE__, list}, cidrs)
        cidrs

      cidrs ->
        cidrs
    end
  end

  defp parse_cidr!({ip, bits} = cidr) when is_tuple(ip) and is_integer(bits), do: cidr

  defp parse_cidr!(text) when is_binary(text) do
    {address, bits} =
      case String.split(text, "/") do
        [address] -> {address, nil}
        [address, bits] -> {address, bits}
        _ -> invalid!(text)
      end

    ip =
      case :inet.parse_strict_address(String.to_charlist(address)) do
        {:ok, ip} -> ip
        {:error, _} -> invalid!(text)
      end

    case bits do
      nil -> host_cidr(unmap(ip))
      bits -> network_cidr(ip, bits, text)
    end
  end

  defp parse_cidr!(other), do: invalid!(other)

  defp host_cidr(ip), do: {ip, if(tuple_size(ip) == 4, do: 32, else: 128)}

  # A prefix on an IPv4-mapped IPv6 address is ambiguous: write the IPv4 network.
  defp network_cidr(ip, bits, text) do
    max_bits = if tuple_size(ip) == 4, do: 32, else: 128

    # Canonical decimal only: `8`, not `+8`, `08` or ` 8`.
    with true <- Regex.match?(~r/\A(0|[1-9][0-9]{0,2})\z/, bits),
         n = String.to_integer(bits),
         true <- n <= max_bits,
         true <- unmap(ip) == ip do
      {ip, n}
    else
      _ -> invalid!(text)
    end
  end

  defp invalid!(text),
    do:
      raise(
        ArgumentError,
        "invalid trusted proxy #{inspect(text)}; use a CIDR such as 10.0.0.0/8"
      )

  defp trusted?(ip, cidrs), do: Enum.any?(cidrs, &in_cidr?(ip, &1))

  defp in_cidr?(ip, {network, bits}) when tuple_size(ip) == tuple_size(network) do
    size = if tuple_size(ip) == 4, do: 32, else: 128
    shift = size - bits
    to_int(ip) >>> shift == to_int(network) >>> shift
  end

  defp in_cidr?(_ip, _cidr), do: false

  defp forwarded_client(conn, cidrs) do
    conn
    |> Plug.Conn.get_req_header("x-forwarded-for")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.reverse()
    |> walk(cidrs)
  end

  defp walk([], _cidrs), do: nil

  defp walk([entry | rest], cidrs) do
    case :inet.parse_strict_address(String.to_charlist(entry)) do
      {:ok, ip} ->
        ip = unmap(ip)
        if trusted?(ip, cidrs), do: walk(rest, cidrs), else: ip

      {:error, _} ->
        nil
    end
  end

  defp unmap({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do: {hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF}

  defp unmap(ip), do: ip

  defp prefix({a, b, c, d, _e, _f, _g, _h}), do: {:ip6_64, a, b, c, d}
  defp prefix(ip), do: ip

  defp to_int({a, b, c, d}), do: a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d

  defp to_int(ip) when tuple_size(ip) == 8,
    do: ip |> Tuple.to_list() |> Enum.reduce(0, fn group, acc -> acc <<< 16 ||| group end)
end
