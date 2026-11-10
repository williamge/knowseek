defmodule Knowseek.Search.FtsQueryTest do
  use ExUnit.Case, async: true

  alias Knowseek.Search.FtsQuery

  doctest FtsQuery

  describe "build/1" do
    test "quotes every word and ANDs them" do
      assert FtsQuery.build("octopus hearts") == ~s("octopus" AND "hearts")
      assert FtsQuery.build("  Octopus   HEARTS ") == ~s("octopus" AND "hearts")
    end

    test "drops Postgres's English stop words outside phrases" do
      assert FtsQuery.build("why is the sky blue") == ~s("sky" AND "blue")
      assert FtsQuery.build("what is the capital of japan") == ~s("capital" AND "japan")
      assert MapSet.size(FtsQuery.stop_words()) == 127
    end

    test "splits words as the unicode61 tokenizer does" do
      assert FtsQuery.build("what's new") == ~s("new")
      assert FtsQuery.build("e-mail covid-19") == ~s("e" AND "mail" AND "covid" AND "19")
      assert FtsQuery.build("Café crème") == ~s("café" AND "crème")
    end

    test "is nil when nothing is left to match" do
      for query <- ["", "   ", "the of and", "!!! ***", "what's", ~s(""), "or", "-"] do
        assert FtsQuery.build(query) == nil, inspect(query)
      end
    end

    test "keeps a quoted phrase whole, stop words included" do
      assert FtsQuery.build(~s("theory of relativity")) == ~s("theory of relativity")

      assert FtsQuery.build(~s(einstein "theory of relativity")) ==
               ~s("einstein" AND "theory of relativity")

      assert FtsQuery.build(~s(einstein "theory of relativity)) ==
               ~s("einstein" AND "theory of relativity")
    end

    test "or matches either side and binds tighter than AND" do
      assert FtsQuery.build("coffee or tea") == ~s[("coffee" OR "tea")]
      assert FtsQuery.build("milk coffee OR tea") == ~s["milk" AND ("coffee" OR "tea")]
      assert FtsQuery.build("coffee or tea or juice") == ~s[("coffee" OR "tea" OR "juice")]
      assert FtsQuery.build(~s("green tea" or coffee)) == ~s[("green tea" OR "coffee")]
    end

    test "ignores an or without a word on both sides" do
      assert FtsQuery.build("or coffee") == ~s("coffee")
      assert FtsQuery.build("coffee or") == ~s("coffee")
      assert FtsQuery.build("coffee or or tea") == ~s[("coffee" OR "tea")]
    end

    test "a leading - excludes a word or a phrase" do
      assert FtsQuery.build("programming language -python") ==
               ~s[("programming" AND "language") NOT "python"]

      assert FtsQuery.build(~s(jazz -"miles davis" -trumpet)) ==
               ~s[("jazz") NOT "miles davis" NOT "trumpet"]

      # As in websearch_to_tsquery, an excluded stop word is dropped.
      assert FtsQuery.build("jazz -the") == ~s("jazz")
    end

    test "exclusions alone match nothing" do
      assert FtsQuery.build("-python") == nil
      assert FtsQuery.build(~s(-python -"monty python")) == nil
    end

    test "never passes FTS5 syntax through" do
      assert FtsQuery.build("cats AND dogs") == ~s("cats" AND "dogs")
      assert FtsQuery.build("NEAR(cats dogs, 5)") == ~s("near" AND "cats" AND "dogs" AND "5")

      assert FtsQuery.build("cat* ^dog content:fish") ==
               ~s("cat" AND "dog" AND "content" AND "fish")

      assert FtsQuery.build(~s(say "hi" "")) == ~s("say" AND "hi")
      assert FtsQuery.build("NOT cats") == ~s("cats")
    end
  end
end
