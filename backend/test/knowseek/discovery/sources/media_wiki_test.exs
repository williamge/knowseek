defmodule Knowseek.Discovery.Sources.MediaWikiTest do
  use ExUnit.Case, async: true

  # `discover/2` is tested through its sources: wikipedia_test.exs and
  # wikibooks_test.exs.
  alias Knowseek.Discovery.Sources.MediaWiki

  describe "truncate/2" do
    test "keeps a body that fits" do
      assert MediaWiki.truncate("short", 10) == "short"
    end

    test "cuts at the last paragraph break before the limit" do
      body = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."
      assert MediaWiki.truncate(body, 40) == "First paragraph.\n\nSecond paragraph."
    end

    test "cuts at the limit when there is no paragraph break" do
      assert MediaWiki.truncate("abcdefghij", 4) == "abcd"
    end

    test "cuts at the limit when the last paragraph break is in the first half" do
      body = "Lead.\n\n" <> String.duplicate("x", 100)
      assert MediaWiki.truncate(body, 50) == String.slice(body, 0, 50)
    end
  end

  describe "search_text/1" do
    test "keeps a query that fits" do
      assert MediaWiki.search_text("octopus intelligence") == "octopus intelligence"
    end

    test "cuts a long query at the last word boundary before 300 code points" do
      query = String.duplicate("octopus ", 45)
      text = MediaWiki.search_text(query)

      assert String.length(text) <= 300
      assert String.ends_with?(text, "octopus")
    end

    test "cuts at 300 code points when there is no space" do
      assert "x" |> String.duplicate(400) |> MediaWiki.search_text() |> String.length() == 300
    end

    test "counts code points, not graphemes" do
      # "é" as "e" plus a combining accent: one grapheme, two code points.
      text = "e\u0301" |> String.duplicate(200) |> MediaWiki.search_text()

      assert length(String.codepoints(text)) == 300
    end
  end

  describe "revision_time/1" do
    test "parses the latest revision's timestamp" do
      assert MediaWiki.revision_time([%{"timestamp" => "2026-10-29T03:01:48Z"}]) ==
               ~U[2026-10-29 03:01:48Z]
    end

    test "is nil without a revision or with an unparseable timestamp" do
      assert MediaWiki.revision_time(nil) == nil
      assert MediaWiki.revision_time([]) == nil
      assert MediaWiki.revision_time([%{"timestamp" => "yesterday"}]) == nil
    end
  end

  describe "monthly_views/1" do
    test "averages the days with data and scales to 30 days" do
      assert MediaWiki.monthly_views(%{"2026-10-01" => 100, "2026-10-02" => 200}) == 4_500
    end

    test "ignores days without data" do
      assert MediaWiki.monthly_views(%{"2026-10-01" => 100, "2026-10-02" => nil}) == 3_000
    end

    test "is nil when no day has data or the API sent nothing" do
      assert MediaWiki.monthly_views(%{"2026-10-01" => nil}) == nil
      assert MediaWiki.monthly_views(%{}) == nil
      assert MediaWiki.monthly_views(nil) == nil
    end

    test "a page with zero views has zero" do
      assert MediaWiki.monthly_views(%{"2026-10-01" => 0}) == 0
    end
  end
end
