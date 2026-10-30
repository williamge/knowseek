defmodule Knowseek.SearchTest do
  use Knowseek.DataCase, async: true

  alias Knowseek.Search
  alias Knowseek.Search.{Coverage, Hit}

  describe "search/2" do
    test "returns no hits and :none coverage for an empty index" do
      assert {:ok, %{hits: [], coverage: :none}} = Search.search("anything")
    end

    test "ranks a document that matches both keyword and vector search first" do
      match =
        document_fixture(body: "Postgres supports vector search with the pgvector extension.")

      _other = document_fixture(body: "Sourdough bread needs a long, slow fermentation.")

      {:ok, %{hits: [top | _]}} = Search.search("pgvector extension")

      assert %Hit{document_id: id, keyword_rank: 1, semantic_rank: 1} = top
      assert id == match.id
    end

    test "respects :limit" do
      for i <- 1..5, do: document_fixture(body: "elixir note #{i}")
      assert {:ok, %{hits: hits}} = Search.search("elixir", limit: 2)
      assert length(hits) == 2
    end
  end

  describe "Coverage.assess/2" do
    test "counts keyword matches and similar hits as strong" do
      keyword = %Hit{keyword_rank: 1, similarity: 0.1}
      similar = %Hit{keyword_rank: nil, similarity: 0.9}
      weak = %Hit{keyword_rank: nil, similarity: 0.1}
      opts = [min_similarity: 0.5, min_strong_hits: 2]

      assert Coverage.assess([], opts) == :none
      assert Coverage.assess([weak], opts) == :none
      assert Coverage.assess([keyword, weak], opts) == :partial
      assert Coverage.assess([keyword, similar], opts) == :sufficient
    end

    test "lowers the strong-hit threshold to :limit" do
      keyword = %Hit{keyword_rank: 1, similarity: 0.1}
      opts = [min_similarity: 0.5, min_strong_hits: 3]

      assert Coverage.assess([keyword], opts) == :partial
      assert Coverage.assess([keyword], Keyword.put(opts, :limit, 1)) == :sufficient
    end
  end
end
