defmodule Knowseek.SearchHnswTest do
  @moduledoc """
  Guard for task 044 / ADR 0024: the vector half of `Knowseek.Search` must
  return the live nearest chunks while dead HNSW entries (deleted or replaced
  chunks that no vacuum has removed) crowd the scan.

  This is the one sanctioned exception to "index scans are off in tests"
  (`config/test.exs`, AGENTS.md "Testing rules"). It isolates itself:

    * It runs against its own connection pool (a dynamic `Knowseek.Repo`,
      outside the SQL sandbox), so its rows are really committed and the
      HNSW index really holds dead entries. The pool starts every connection
      with `enable_indexscan = on` and `enable_seqscan = off`; no other test
      sees those settings.
    * The module is not async. ExUnit runs it alone, after every async
      module, so the table locks it takes cannot meet another test.
    * It truncates `chunks` and `documents` before it starts (a fresh index,
      without the dead entries that earlier tests leave: the rows they roll
      back stay in the index), turns autovacuum off for `chunks` (a vacuum
      would remove the dead entries mid-test), and undoes both in `on_exit`.
      The truncate empties the tables, so nothing it committed outlives it.

  Tagged `:hnsw_guard`: `mix test --only hnsw_guard`.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Knowseek.{Documents, Repo, Search}
  alias Knowseek.Documents.Document

  @moduletag :hnsw_guard

  # Words of the query. Every dead chunk repeats them (a look-alike of the
  # query); the live match has 16 of the 24.
  @base ~w(amber basalt cobalt dune ember fjord glacier harbor island jasper kelp lagoon
           meadow nebula oasis prairie quartz reef summit tundra umber valley willow xenon)
  # Three live documents that share 20, 16 and 13 of the query's 24 words (the
  # rest are words of their own), so their similarities differ: about 0.83,
  # 0.67 and 0.54, all above the relevance floor (`min_similarity` 0.5). They
  # share too few words for the full-text search to match (that needs all 24),
  # so only the vector search finds them, and its order is their order.
  @live [
    {"near", 20, ~w(copper delta flint garnet)},
    {"middle", 16, ~w(copper delta flint garnet heron ivory lichen marble)},
    {"far", 13, ~w(copper delta flint garnet heron ivory lichen marble opal pearl quill rust)}
  ]
  @query Enum.join(@base, " ")

  # One body is 20 paragraphs of about 900 characters: the chunker packs
  # paragraphs up to 1200 characters, so each stays its own chunk. 26 versions
  # of it leave 520 dead entries. `limit: 10` asks the scan for 400
  # (`hnsw.ef_search`): with 400 dead look-alikes the scan already comes back
  # empty (measured: 14 and 18 versions, 280 and 360 dead entries, still find
  # the live chunk; 20 and 21 do not), and 520 keeps a margin of 30%.
  @paragraphs 20
  @versions 26

  setup do
    config =
      :knowseek
      |> Application.fetch_env!(Repo)
      |> Keyword.merge(
        name: nil,
        pool: DBConnection.ConnectionPool,
        pool_size: 2,
        parameters: [enable_indexscan: "on", enable_seqscan: "off", lock_timeout: "15s"]
      )

    on_exit(fn -> cleanup!(config) end)

    sql!(config, "ALTER TABLE chunks SET (autovacuum_enabled = false)")
    sql!(config, "TRUNCATE chunks, documents CASCADE")

    repo = start_supervised!({Repo, config})
    Repo.put_dynamic_repo(repo)

    search_env = Application.fetch_env!(:knowseek, Search)
    on_exit(fn -> Application.put_env(:knowseek, Search, search_env) end)

    :ok
  end

  test "a scan crowded by dead look-alikes returns nothing without iterative scan, the live documents in order with it" do
    live = ingest_live_documents()
    churn_then_delete_document()

    assert Repo.aggregate(Document, :count) == 23
    assert uses_hnsw_index?()
    expected = Enum.map(live, & &1.id)

    # The exact answer: what the vector query returns with the index off.
    exact = search(iterative_scan: :off, exact: true)
    assert Enum.map(exact, & &1.document_id) == expected
    assert Enum.map(exact, & &1.semantic_rank) == [1, 2, 3]
    assert exact |> Enum.map(& &1.similarity) |> Enum.all?(&(&1 >= 0.5))
    similarities = Enum.map(exact, & &1.similarity)
    assert similarities == Enum.sort(similarities, :desc)
    assert length(Enum.uniq(similarities)) == 3

    # The problem: 520 dead entries nearer than the live chunks fill the scan.
    # This and the next assertion document pgvector's behaviour: if a later
    # pgvector walks past dead entries by itself, the first one fails, and the
    # iterative scan is no longer needed (ADR 0024).
    assert search(iterative_scan: :off) == []

    # The fix: the iterative scan walks past the dead entries, and strict_order
    # returns the rows in the exact scan's order (RRF ranks by position).
    for hits <- [search(iterative_scan: :strict_order), search([])] do
      assert Enum.map(hits, & &1.document_id) == expected
      assert Enum.map(hits, & &1.semantic_rank) == [1, 2, 3]
      assert Enum.all?(hits, &(&1.keyword_rank == nil))

      for {hit, exact_hit} <- Enum.zip(hits, exact),
          do: assert_in_delta(hit.similarity, exact_hit.similarity, 1.0e-6)
    end
  end

  # The live documents of `@live`, best match first, and twenty unrelated ones.
  defp ingest_live_documents do
    live =
      for {name, shared, own} <- @live do
        words = Enum.take(@base, shared) ++ Enum.take(own, 24 - shared)

        {:ok, document} =
          Documents.ingest(%{url: "https://hnsw.test/#{name}", source: "hnsw", body: body(words)})

        document
      end

    for n <- 1..20 do
      words = for i <- 1..24, do: "filler#{n}x#{i}"

      {:ok, _} =
        Documents.ingest(%{url: "https://hnsw.test/f#{n}", source: "hnsw", body: body(words)})
    end

    live
  end

  # Every re-ingest replaces the chunks (the old ones stay in the index as
  # dead entries); the delete leaves the last version's chunks dead too.
  defp churn_then_delete_document do
    for version <- 1..@versions do
      paragraphs =
        for p <- 1..@paragraphs do
          words = List.duplicate(@base, 6) |> List.flatten()
          Enum.join(words ++ ["version#{version}", "paragraph#{p}"], " ")
        end

      {:ok, _} =
        Documents.ingest(%{
          url: "https://hnsw.test/churned",
          source: "hnsw",
          body: Enum.join(paragraphs, "\n\n")
        })
    end

    {1, _} = Repo.delete_all(from d in Document, where: d.url == "https://hnsw.test/churned")
  end

  defp body(words), do: words |> List.duplicate(6) |> List.flatten() |> Enum.join(" ")

  # The vector query's shape, planned the way this pool plans (index scans
  # on, sequential scans off): it must use the HNSW index.
  defp uses_hnsw_index? do
    {:ok, plan} =
      Repo.transaction(fn ->
        vector = Pgvector.new(List.duplicate(0.1, 1024))

        Repo.query!(
          "EXPLAIN SELECT id FROM chunks WHERE embedding IS NOT NULL " <>
            "ORDER BY embedding <=> $1 LIMIT 400",
          [vector]
        ).rows
        |> Enum.map_join("\n", &hd/1)
      end)

    plan =~ "chunks_embedding_vector_cosine_ops_index"
  end

  # Runs `Search.search/2` for the query and returns the hits. `iterative_scan:`
  # sets the config for this call. `exact: true` plans an exact scan on this
  # connection (index scans off, sequential scans back on), the reference answer.
  defp search(opts) do
    env = Application.fetch_env!(:knowseek, Search)

    case Keyword.fetch(opts, :iterative_scan) do
      {:ok, mode} ->
        Application.put_env(:knowseek, Search, Keyword.put(env, :iterative_scan, mode))

      :error ->
        :ok
    end

    try do
      Repo.checkout(fn ->
        if opts[:exact] do
          Repo.query!("SET enable_indexscan = off")
          Repo.query!("SET enable_seqscan = on")
        end

        try do
          {:ok, %{hits: hits}} = Search.search(@query, limit: 10)
          hits
        after
          Repo.query!("RESET enable_indexscan")
          Repo.query!("RESET enable_seqscan")
        end
      end)
    after
      Application.put_env(:knowseek, Search, env)
    end
  end

  # Both steps always run, even when the first raises (a lock timeout, a dead
  # connection): leaving autovacuum off for `chunks` is the worse leftover. The
  # first error is raised after both. A run that is killed before this runs
  # (Ctrl-C, a CI timeout) leaves its rows and the autovacuum setting behind: run
  # the guard again, or `TRUNCATE chunks, documents CASCADE` and
  # `ALTER TABLE chunks RESET (autovacuum_enabled)` in the test database.
  defp cleanup!(config) do
    errors =
      for statement <- [
            "ALTER TABLE chunks RESET (autovacuum_enabled)",
            "TRUNCATE chunks, documents CASCADE"
          ],
          reduce: [] do
        errors ->
          try do
            sql!(config, statement)
            errors
          rescue
            error -> [error | errors]
          end
      end

    case Enum.reverse(errors) do
      [] -> :ok
      [first | _] -> raise first
    end
  end

  # One short-lived connection, so cleanup works after the test's pool is gone.
  defp sql!(config, statement) do
    {:ok, conn} =
      config
      |> Keyword.take([:hostname, :port, :username, :password, :database])
      |> Keyword.put(:parameters, lock_timeout: "15s")
      |> Postgrex.start_link()

    try do
      Postgrex.query!(conn, statement, [])
    after
      GenServer.stop(conn)
    end
  end
end
