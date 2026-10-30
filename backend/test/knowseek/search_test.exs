defmodule Knowseek.SearchTest do
  use Knowseek.DataCase, async: true

  alias Knowseek.Search
  alias Knowseek.Search.{Coverage, Hit}

  @now ~U[2026-06-01 12:00:00Z]
  @old ~U[2020-01-01 00:00:00Z]

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

    test "returns published_at on hits" do
      published = ~U[2026-01-02 03:04:05Z]
      document_fixture(body: "Aurora borealis season.", published_at: published)

      assert {:ok, %{hits: [%Hit{published_at: ^published}]}} = Search.search("aurora borealis")
    end

    test "applies :max_age_seconds to coverage" do
      for i <- 1..3, do: document_fixture(body: "Comet tails, part #{i}.", fetched_at: @old)

      assert {:ok, %{coverage: :sufficient}} = Search.search("comet tails")
      assert {:ok, %{coverage: :none}} = Search.search("comet tails", max_age_seconds: 3600)
    end

    test "returns no hits for a query that the index does not cover" do
      document_fixture(body: "Sourdough bread needs a long, slow fermentation.")
      document_fixture(body: "Postgres supports vector search with the pgvector extension.")

      assert {:ok, %{hits: [], coverage: :none}} = Search.search("heavy metal")
    end

    test "returns only the relevant hits when some chunks match" do
      match = document_fixture(body: "Octopuses have three hearts and nine brains.")
      _other = document_fixture(body: "Sourdough bread needs a long, slow fermentation.")

      assert {:ok, %{hits: hits}} = Search.search("octopuses")
      assert Enum.map(hits, & &1.document_id) == [match.id]
    end

    test "keeps a hit that matches by similarity but not by keyword" do
      match = document_fixture(body: "alpha beta gamma delta")

      # The full-text query needs every term, so "epsilon" rules out a keyword match.
      assert {:ok, %{hits: [hit]}} = Search.search("alpha beta gamma delta epsilon")
      assert hit.document_id == match.id
      assert hit.keyword_rank == nil
      assert hit.similarity >= 0.5
    end

    test "applies :min_similarity" do
      document_fixture(body: "alpha beta gamma delta")
      query = "alpha beta gamma delta epsilon"

      assert {:ok, %{hits: [_]}} = Search.search(query, min_similarity: 0.5)
      assert {:ok, %{hits: []}} = Search.search(query, min_similarity: 0.99)
    end

    test "does not let irrelevant chunks use up :limit" do
      match = document_fixture(body: "Octopuses have three hearts and nine brains.")
      for i <- 1..5, do: document_fixture(body: "Sourdough bread, loaf #{i}.")

      assert {:ok, %{hits: [hit]}} = Search.search("octopuses", limit: 1)
      assert hit.document_id == match.id
    end

    test "respects :limit" do
      for i <- 1..5, do: document_fixture(body: "elixir note #{i}")
      assert {:ok, %{hits: hits}} = Search.search("elixir", limit: 2)
      assert length(hits) == 2
    end
  end

  describe "Coverage.assess/2" do
    test "counts keyword matches and similar hits as strong" do
      keyword = hit(keyword_rank: 1, similarity: 0.1)
      similar = hit(keyword_rank: nil, similarity: 0.9)
      weak = hit(keyword_rank: nil, similarity: 0.1)
      opts = [min_similarity: 0.5, min_strong_hits: 2]

      assert Coverage.assess([], opts) == :none
      assert Coverage.assess([weak], opts) == :none
      assert Coverage.assess([keyword, weak], opts) == :partial
      assert Coverage.assess([keyword, similar], opts) == :sufficient
    end

    test "lowers the strong-hit threshold to :limit" do
      keyword = hit(keyword_rank: 1, similarity: 0.1)
      opts = [min_similarity: 0.5, min_strong_hits: 3]

      assert Coverage.assess([keyword], opts) == :partial
      assert Coverage.assess([keyword], Keyword.put(opts, :limit, 1)) == :sufficient
    end

    test "counts distinct documents, not chunks" do
      document_id = Ecto.UUID.generate()
      chunks = for _ <- 1..3, do: hit(document_id: document_id, keyword_rank: 1)
      opts = [min_similarity: 0.5, min_strong_hits: 2]

      assert Coverage.assess(chunks, opts) == :partial
      assert Coverage.assess([hit(keyword_rank: 1) | chunks], opts) == :sufficient
    end

    test "ignores age when :max_age_seconds is nil" do
      old = hit(keyword_rank: 1, fetched_at: @old)
      opts = [min_similarity: 0.5, min_strong_hits: 1, max_age_seconds: nil, now: @now]

      assert Coverage.assess([old], opts) == :sufficient
    end

    test "does not count hits older than :max_age_seconds as strong" do
      opts = [min_similarity: 0.5, min_strong_hits: 2, max_age_seconds: 3600, now: @now]
      fresh = hit(keyword_rank: 1, fetched_at: DateTime.add(@now, -3600, :second))
      stale = hit(keyword_rank: 1, fetched_at: DateTime.add(@now, -3601, :second))

      assert Coverage.assess([stale, stale], opts) == :none
      assert Coverage.assess([fresh, stale], opts) == :partial
      assert Coverage.assess([fresh, hit(keyword_rank: 1, fetched_at: @now)], opts) == :sufficient
    end

    test "uses fetched_at, not published_at, for the age" do
      opts = [min_similarity: 0.5, min_strong_hits: 1, max_age_seconds: 3600, now: @now]
      refetched = hit(keyword_rank: 1, published_at: @old, fetched_at: @now)
      stale = hit(keyword_rank: 1, published_at: @now, fetched_at: @old)

      assert Coverage.assess([refetched], opts) == :sufficient
      assert Coverage.assess([stale], opts) == :none
    end

    test "does not count a hit fetched in the future as fresh" do
      opts = [min_similarity: 0.5, min_strong_hits: 1, max_age_seconds: 3600, now: @now]
      future = hit(keyword_rank: 1, fetched_at: DateTime.add(@now, 1, :second))

      assert Coverage.assess([future], opts) == :none
    end

    test "does not count fresh but irrelevant hits as strong" do
      opts = [min_similarity: 0.5, min_strong_hits: 1, max_age_seconds: 3600, now: @now]

      assert Coverage.assess([hit(similarity: 0.1, fetched_at: @now)], opts) == :none
    end
  end

  defp hit(attrs) do
    struct!(Hit, Keyword.merge([document_id: Ecto.UUID.generate(), fetched_at: @now], attrs))
  end
end
