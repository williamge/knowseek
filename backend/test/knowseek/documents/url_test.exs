defmodule Knowseek.Documents.URLTest do
  use ExUnit.Case, async: true

  alias Knowseek.Documents.URL

  describe "canonicalize/1" do
    test "lowercases the scheme and the host but not the path" do
      assert URL.canonicalize("HTTPS://Example.COM/Some/Path") == "https://example.com/Some/Path"
    end

    test "drops the fragment" do
      assert URL.canonicalize("https://example.com/a#section") == "https://example.com/a"
      assert URL.canonicalize("https://example.com/a?x=1#section") == "https://example.com/a?x=1"
    end

    test "drops default ports and keeps other ports" do
      assert URL.canonicalize("http://example.com:80/a") == "http://example.com/a"
      assert URL.canonicalize("https://example.com:443/a") == "https://example.com/a"
      assert URL.canonicalize("https://example.com:80/a") == "https://example.com:80/a"
      assert URL.canonicalize("http://example.com:8080/a") == "http://example.com:8080/a"
    end

    test "gives an empty path a slash" do
      assert URL.canonicalize("https://example.com") == "https://example.com/"
      assert URL.canonicalize("https://example.com?a=1") == "https://example.com/?a=1"
      assert URL.canonicalize("https://example.com/") == "https://example.com/"
    end

    test "keeps trailing slashes on other paths" do
      assert URL.canonicalize("https://example.com/a/") == "https://example.com/a/"
    end

    test "drops tracking parameters" do
      url =
        "https://example.com/a?utm_source=x&UTM_Medium=y&fbclid=1&gclid=2&mc_cid=3&mc_eid=4&id=7"

      assert URL.canonicalize(url) == "https://example.com/a?id=7"
    end

    test "drops the query when only tracking parameters remain" do
      assert URL.canonicalize("https://example.com/a?utm_source=x&fbclid=1") ==
               "https://example.com/a"
    end

    test "keeps parameters that only look like trackers" do
      assert URL.canonicalize("https://example.com/a?utm=1&source=2&xutm_a=3") ==
               "https://example.com/a?source=2&utm=1&xutm_a=3"
    end

    test "sorts query parameters and keeps repeated names" do
      assert URL.canonicalize("https://example.com/a?b=2&a=2&a=1") ==
               "https://example.com/a?a=1&a=2&b=2"
    end

    test "keeps parameter encoding as given" do
      assert URL.canonicalize("https://example.com/a?q=a%20b&r=a+b") ==
               "https://example.com/a?q=a%20b&r=a+b"
    end

    test "gives equal results for variants of one page" do
      variants = [
        "https://example.com/a?x=1&y=2",
        "HTTPS://EXAMPLE.COM:443/a?y=2&x=1#top",
        "https://example.com/a?utm_campaign=c&y=2&x=1"
      ]

      assert variants |> Enum.map(&URL.canonicalize/1) |> Enum.uniq() |> length() == 1
    end

    test "handles IPv6 hosts" do
      assert URL.canonicalize("http://[::1]:80/a") == "http://[::1]/a"

      assert URL.canonicalize("HTTPS://[2001:DB8::1]:8443/a?b=1") ==
               "https://[2001:db8::1]:8443/a?b=1"
    end

    test "drops an empty query" do
      assert URL.canonicalize("https://example.com/a?") == "https://example.com/a"
      assert URL.canonicalize("https://example.com/a?&&") == "https://example.com/a"
    end

    test "keeps userinfo" do
      assert URL.canonicalize("https://user:pw@Example.com/a") == "https://user:pw@example.com/a"
    end

    test "trims surrounding whitespace" do
      assert URL.canonicalize("  https://example.com/a \n") == "https://example.com/a"
    end

    test "is idempotent" do
      once = URL.canonicalize("HTTP://Example.com:80?b=1&a=2&utm_x=1#f")
      assert URL.canonicalize(once) == once
    end

    test "leaves other schemes and unparseable text alone" do
      assert URL.canonicalize("urn:knowseek:sha256:ABC") == "urn:knowseek:sha256:ABC"
      assert URL.canonicalize("ftp://Example.com/a#b") == "ftp://Example.com/a#b"
      assert URL.canonicalize("not a url") == "not a url"
    end
  end

  describe "tracking_param?/1" do
    test "matches by prefix and by name, ignoring case" do
      assert URL.tracking_param?("utm_term")
      assert URL.tracking_param?("FBCLID")
      assert URL.tracking_param?("mc_eid")
      refute URL.tracking_param?("id")
    end
  end
end
