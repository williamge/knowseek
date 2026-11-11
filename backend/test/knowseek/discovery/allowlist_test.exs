defmodule Knowseek.Discovery.AllowlistTest do
  use ExUnit.Case, async: true

  alias Knowseek.Discovery.Allowlist

  describe "parse/1" do
    test "lowercases scheme and host, drops the fragment, keeps path and query byte for byte" do
      assert {:ok, %{url: "https://example.org/Path/A%20b?Q=1&z=%7E", host: "example.org"}} =
               Allowlist.parse("HTTPS://Example.ORG/Path/A%20b?Q=1&z=%7E#section")
    end

    test "gives a protocol-relative URL https" do
      assert {:ok, %{url: "https://example.com/x", host: "example.com"}} =
               Allowlist.parse("//example.com/x")
    end

    test "trims the text" do
      assert {:ok, %{url: "http://example.com/"}} = Allowlist.parse("  http://example.com/ \n")
    end

    test "strips www. from the host only, not from the url" do
      assert {:ok, %{url: "http://www.example.com/a", host: "example.com"}} =
               Allowlist.parse("http://www.Example.com/a")

      assert {:ok, %{host: "web.archive.org"}} =
               Allowlist.parse("https://web.archive.org/web/1/x")
    end

    test "is :error for anything that is not a web link" do
      for text <- [
            "mailto:someone@example.org",
            "ftp://example.org/file",
            "irc://irc.example.org/chan",
            "just some text",
            "https:///no-host",
            "",
            "https://example.org/" <> String.duplicate("a", 2_000)
          ] do
        assert Allowlist.parse(text) == :error, "expected :error for #{inspect(text)}"
      end
    end

    test "is :error for a value that is no string" do
      assert Allowlist.parse(nil) == :error
    end
  end

  describe "allowed?/1" do
    test "is true for an allowed host, also behind www." do
      assert Allowlist.allowed?("https://en.wikipedia.org/wiki/X")
      assert Allowlist.allowed?("http://www.en.wikibooks.org/")
      assert Allowlist.allowed?("//en.wikipedia.org/wiki/X")
    end

    test "is false for other hosts, even other Wikimedia ones" do
      refute Allowlist.allowed?("https://en.m.wikipedia.org/wiki/X")
      refute Allowlist.allowed?("https://commons.wikimedia.org/wiki/File:X.png")
      refute Allowlist.allowed?("https://example.org/en.wikipedia.org")
    end

    test "is false for a non-URL" do
      refute Allowlist.allowed?("en.wikipedia.org")
      refute Allowlist.allowed?("mailto:en.wikipedia.org")
    end
  end

  test "hosts/0 reads config" do
    assert Allowlist.hosts() == ["en.wikipedia.org", "en.wikibooks.org"]
  end
end
