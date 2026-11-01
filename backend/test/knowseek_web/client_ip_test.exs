defmodule KnowseekWeb.ClientIpTest do
  use ExUnit.Case, async: true

  alias KnowseekWeb.ClientIp

  defp conn(remote_ip, forwarded \\ []) do
    forwarded
    |> List.wrap()
    |> Enum.reduce(%{Plug.Test.conn(:get, "/") | remote_ip: remote_ip}, fn value, conn ->
      %{conn | req_headers: conn.req_headers ++ [{"x-forwarded-for", value}]}
    end)
  end

  describe "without trusted proxies (the default)" do
    test "the client is the socket address" do
      assert ClientIp.key(conn({203, 0, 113, 7})) == {203, 0, 113, 7}
    end

    test "X-Forwarded-For is ignored, so it cannot be spoofed" do
      conn = conn({203, 0, 113, 7}, "198.51.100.1, 198.51.100.2")
      assert ClientIp.key(conn) == {203, 0, 113, 7}
      assert ClientIp.key(conn, []) == {203, 0, 113, 7}
    end
  end

  describe "with trusted proxies" do
    @proxies ["10.0.0.0/8", "fd00::/8"]

    test "the client is the rightmost address that is not a trusted proxy" do
      conn = conn({10, 0, 0, 5}, "198.51.100.1, 203.0.113.9, 10.1.2.3")
      assert ClientIp.key(conn, @proxies) == {203, 0, 113, 9}
    end

    test "what the client wrote on the left does not count" do
      # The client sent `9.9.9.9`; the proxy appended the address it saw.
      conn = conn({10, 0, 0, 5}, "9.9.9.9, 203.0.113.9")
      assert ClientIp.key(conn, @proxies) == {203, 0, 113, 9}
    end

    test "reads several header lines in order" do
      conn = conn({10, 0, 0, 5}, ["203.0.113.9", "10.9.9.9"])
      assert ClientIp.key(conn, @proxies) == {203, 0, 113, 9}
    end

    test "a socket address that is not a trusted proxy is the client, header or not" do
      conn = conn({203, 0, 113, 7}, "198.51.100.1")
      assert ClientIp.key(conn, @proxies) == {203, 0, 113, 7}
    end

    test "without a header, or with a rightmost entry that is no address, the client is the proxy" do
      assert ClientIp.key(conn({10, 0, 0, 5}), @proxies) == {10, 0, 0, 5}
      assert ClientIp.key(conn({10, 0, 0, 5}, "1.2.3.4, unknown"), @proxies) == {10, 0, 0, 5}
      assert ClientIp.key(conn({10, 0, 0, 5}, ""), @proxies) == {10, 0, 0, 5}
    end

    test "a chain of only trusted proxies is the proxy" do
      assert ClientIp.key(conn({10, 0, 0, 5}, "10.0.0.7, 10.0.0.8"), @proxies) == {10, 0, 0, 5}
    end

    test "an IPv6 proxy and an IPv4-mapped socket address" do
      v6 = {0xFD00, 0, 0, 0, 0, 0, 0, 1}
      assert ClientIp.key(conn(v6, "203.0.113.9"), @proxies) == {203, 0, 113, 9}

      mapped = {0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001}
      assert ClientIp.key(conn(mapped, "203.0.113.9"), @proxies) == {203, 0, 113, 9}
    end

    test "a host address without a prefix is a /32" do
      assert ClientIp.key(conn({127, 0, 0, 1}, "203.0.113.9"), ["127.0.0.1"]) == {203, 0, 113, 9}
      assert ClientIp.key(conn({127, 0, 0, 2}, "203.0.113.9"), ["127.0.0.1"]) == {127, 0, 0, 2}
    end
  end

  describe "the key" do
    test "an IPv4-mapped IPv6 address is the IPv4 address" do
      assert ClientIp.key(conn({0, 0, 0, 0, 0, 0xFFFF, 0xC000, 0x0201})) == {192, 0, 2, 1}
    end

    test "an IPv6 address is its /64 prefix" do
      one = ClientIp.key(conn({0x2001, 0xDB8, 1, 2, 0, 0, 0, 1}))
      other = ClientIp.key(conn({0x2001, 0xDB8, 1, 2, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF}))
      elsewhere = ClientIp.key(conn({0x2001, 0xDB8, 1, 3, 0, 0, 0, 1}))

      assert one == other
      assert one == {:ip6_64, 0x2001, 0xDB8, 1, 2}
      assert elsewhere != one
    end
  end

  describe "parse_cidrs!/1" do
    test "accepts networks and hosts" do
      assert ClientIp.parse_cidrs!(["10.0.0.0/8", "127.0.0.1", "::1", "fd00::/8"]) == [
               {{10, 0, 0, 0}, 8},
               {{127, 0, 0, 1}, 32},
               {{0, 0, 0, 0, 0, 0, 0, 1}, 128},
               {{0xFD00, 0, 0, 0, 0, 0, 0, 0}, 8}
             ]
    end

    test "raises on anything that is not a CIDR, so a typo stops the start" do
      for bad <- ["nonsense", "10.0.0.0/33", "10.0.0.0/x", "10.0.0.0/8/1", "10.0.0/8", "", 5] do
        assert_raise ArgumentError, ~r/invalid trusted proxy/, fn ->
          ClientIp.parse_cidrs!([bad])
        end
      end
    end
  end
end
