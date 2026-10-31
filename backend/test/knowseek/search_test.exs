defmodule Knowseek.SearchTest do
  use Knowseek.DataCase, async: false

  alias Knowseek.Repo
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

  describe "search/2 groups chunks by document" do
    test "a document with many matching chunks is one hit, with the best chunk on top" do
      long = document_fixture(body: long_body("octopus", 6))
      other = document_fixture(body: "The octopus has three hearts.")

      assert {:ok, %{hits: hits}} = Search.search("octopus")

      assert Enum.sort(Enum.map(hits, & &1.document_id)) == Enum.sort([long.id, other.id])
      hit = Enum.find(hits, &(&1.document_id == long.id))

      assert hit.content =~ "octopus"
      assert length(hit.passages) == 3
      scores = Enum.map(hit.passages, & &1.score)
      assert scores == Enum.sort(scores, :desc)
      assert Enum.all?(hit.passages, &(&1.score <= hit.score and &1.content =~ "octopus"))
      refute hit.chunk_id in Enum.map(hit.passages, & &1.chunk_id)

      assert Enum.uniq(Enum.map(hit.passages, & &1.content)) ==
               Enum.map(hit.passages, & &1.content)
    end

    test "a document's score is its best chunk's score, not a sum" do
      document_fixture(body: long_body("octopus", 6))
      assert {:ok, %{hits: [hit]}} = Search.search("octopus")

      # One chunk's RRF score is at most 2 / 61: a sum over 7 chunks would exceed it.
      assert hit.score <= 2 / 61
    end

    test "caps passages at :max_passages" do
      document_fixture(body: long_body("octopus", 8))
      assert {:ok, %{hits: [hit]}} = Search.search("octopus", max_passages: 2)
      assert length(hit.passages) == 2
    end

    test "a single-chunk document has no passages" do
      document_fixture(body: "The octopus has three hearts.")
      assert {:ok, %{hits: [%Hit{passages: []}]}} = Search.search("octopus")
    end

    test "hits come from different documents even when one has more chunks than :limit" do
      hog = document_fixture(body: long_body("octopus", 12))
      others = for i <- 1..3, do: document_fixture(body: "Octopus fact number #{i}.")

      assert {:ok, %{hits: hits}} = Search.search("octopus", limit: 4)

      ids = Enum.map(hits, & &1.document_id)
      assert Enum.sort(ids) == Enum.sort([hog.id | Enum.map(others, & &1.id)])
    end

    test "the default :candidate_factor fills :limit where a small one underfills" do
      # Five equally relevant 35-chunk documents: 3 hits need more than 4 * 3 chunks.
      for _ <- 1..5, do: document_fixture(body: long_body("octopus", 35))

      config = Application.get_env(:knowseek, Search)
      on_exit(fn -> Application.put_env(:knowseek, Search, config) end)

      Application.put_env(:knowseek, Search, Keyword.put(config, :candidate_factor, 4))
      assert {:ok, %{hits: small}} = Search.search("octopus", limit: 3)
      assert length(small) < 3

      Application.put_env(:knowseek, Search, config)
      assert {:ok, %{hits: hits}} = Search.search("octopus", limit: 3)
      assert length(hits) == 3
    end

    test "returns fewer hits than :limit when fewer documents match" do
      document_fixture(body: long_body("octopus", 4))
      assert {:ok, %{hits: [_]}} = Search.search("octopus", limit: 5)
    end

    test "one document with several strong chunks gives :partial coverage" do
      document_fixture(body: long_body("octopus", 5))
      assert {:ok, %{hits: [_], coverage: :partial}} = Search.search("octopus")
    end
  end

  describe "group/2" do
    test "keeps the fused order for documents with equal scores" do
      ranked = [
        %{chunk_id: "a1", document_id: "a", score: 0.5},
        %{chunk_id: "b1", document_id: "b", score: 0.5},
        %{chunk_id: "c1", document_id: "c", score: 0.5},
        %{chunk_id: "a2", document_id: "a", score: 0.5},
        %{chunk_id: "b2", document_id: "b", score: 0.4}
      ]

      grouped = Search.group(ranked, 3)

      assert Enum.map(grouped, & &1.document_id) == ["a", "b", "c"]
      assert Enum.map(grouped, & &1.chunk_id) == ["a1", "b1", "c1"]
      assert [%{chunk_id: "a2"}] = hd(grouped).passages
    end
  end

  describe "ef_search/1 and with_ef_search/2" do
    test "has a floor of 40, scales with the candidates, and caps at 1000" do
      assert Search.ef_search(1) == 40
      assert Search.ef_search(40) == 40
      assert Search.ef_search(400) == 400
      assert Search.ef_search(1000) == 1000
      assert Search.ef_search(50_000) == 1000
    end

    test "applies the setting inside the transaction" do
      read = fn -> Repo.query!("SELECT current_setting('hnsw.ef_search', true)").rows end

      assert [["400"]] = Search.with_ef_search(400, read)
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

  # `count` paragraphs of about 1,000 characters each: the chunker makes one
  # chunk per paragraph.
  defp long_body(word, count) do
    Enum.map_join(1..count, "\n\n", fn i ->
      String.pad_trailing("The #{word} fact #{i} is documented. ", 1_000, "filler text. ")
    end)
  end

  defp hit(attrs) do
    struct!(Hit, Keyword.merge([document_id: Ecto.UUID.generate(), fetched_at: @now], attrs))
  end
end
