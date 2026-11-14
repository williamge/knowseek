defmodule Knowseek.Crawl.Frontier do
  @moduledoc """
  The queries and writes of the two crawl tables, `crawl_sources` and
  `crawl_candidates` (#89, ADR 0033). Internal to `Knowseek.Crawl`. Every
  write is one short transaction, made after the external calls (rule 5).
  """
  import Ecto.Query

  alias Knowseek.Crawl.{Candidate, SourcePage}
  alias Knowseek.Repo

  # Ids bound to one query: far below SQLite's limit on variables.
  @chunk 500

  @doc "The `crawl_sources` rows of the documents `ids`, by document id."
  @spec source_pages([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => SourcePage.t()}
  def source_pages(ids) do
    ids
    |> Enum.chunk_every(@chunk)
    |> Enum.flat_map(&Repo.all(from s in SourcePage, where: s.document_id in ^&1))
    |> Map.new(&{&1.document_id, &1})
  end

  @doc """
  Stores what one read of a source page's links found, in one transaction:
  upserts its `crawl_sources` row, deletes its `pending` candidates and
  inserts `candidate_rows`. A row of a page that is `fetched` or `skipped`
  stays as it is.
  """
  @spec put_source(map(), [map()]) :: :ok
  def put_source(%{document_id: document_id} = source, candidate_rows) do
    {:ok, :ok} =
      Repo.transact(fn ->
        Repo.insert_all(SourcePage, [source],
          on_conflict: {:replace_all_except, [:document_id]},
          conflict_target: :document_id
        )

        Repo.delete_all(
          from c in Candidate,
            where: c.source_document_id == ^document_id and c.state == "pending"
        )

        for chunk <- Enum.chunk_every(candidate_rows, 50) do
          Repo.insert_all(Candidate, chunk, on_conflict: :nothing)
        end

        {:ok, :ok}
      end)

    :ok
  end

  @doc "The ids of `ids` that have a `fetched` or `skipped` candidate row on `site`."
  @spec settled_page_ids(String.t(), [integer()]) :: MapSet.t(integer())
  def settled_page_ids(site, ids) do
    ids
    |> Enum.chunk_every(@chunk)
    |> Enum.flat_map(fn chunk ->
      Repo.all(
        from c in Candidate,
          where: c.site == ^site and c.page_id in ^chunk and c.state in ["fetched", "skipped"],
          select: c.page_id
      )
    end)
    |> MapSet.new()
  end

  @doc """
  The `pending` candidates of the source pages `source_ids` whose `failed_at`
  is empty or older than `retry_before`.
  """
  @spec pending([Ecto.UUID.t()], DateTime.t()) :: [Candidate.t()]
  def pending(source_ids, retry_before) do
    source_ids
    |> Enum.chunk_every(@chunk)
    |> Enum.flat_map(fn chunk ->
      Repo.all(
        from c in Candidate,
          where:
            c.state == "pending" and c.source_document_id in ^chunk and
              (is_nil(c.failed_at) or c.failed_at < ^retry_before)
      )
    end)
  end

  @doc "How many candidates of each source page were `fetched` since `since`."
  @spec spent(DateTime.t()) :: %{Ecto.UUID.t() => non_neg_integer()}
  def spent(since) do
    Repo.all(
      from c in Candidate,
        where: c.state == "fetched" and c.fetched_at >= ^since,
        group_by: c.source_document_id,
        select: {c.source_document_id, count()}
    )
    |> Map.new()
  end

  @doc "How many candidates were `fetched` since `since`."
  @spec fetched_since(DateTime.t()) :: non_neg_integer()
  def fetched_since(since) do
    Repo.one(
      from c in Candidate, where: c.state == "fetched" and c.fetched_at >= ^since, select: count()
    )
  end

  @doc "The last `limit` `fetched` candidates, newest first."
  @spec recent_fetched(pos_integer()) :: [Candidate.t()]
  def recent_fetched(limit) do
    Repo.all(
      from c in Candidate,
        where: c.state == "fetched",
        order_by: [desc: c.fetched_at, desc: c.page_id],
        limit: ^limit
    )
  end

  @doc """
  Marks `candidate` `fetched` with `attrs` (the background page's
  `document_id`, the score parts that decided the fetch, `stored_bytes` and
  `fetched_at`) and deletes the other `pending` rows of the same page, in one
  transaction.
  """
  @spec mark_fetched(Candidate.t(), map()) :: :ok
  def mark_fetched(candidate, attrs), do: settle(candidate, Map.put(attrs, :state, "fetched"))

  @doc """
  Marks `candidate` `skipped` (the page gave no text, or its URL is off the
  allowlist) and deletes the other `pending` rows of the same page. A skipped
  page is not a candidate again.
  """
  @spec mark_skipped(Candidate.t()) :: :ok
  def mark_skipped(candidate), do: settle(candidate, %{state: "skipped"})

  defp settle(candidate, attrs) do
    {:ok, :ok} =
      Repo.transact(fn ->
        Repo.update_all(row(candidate), set: Map.to_list(attrs))
        delete_pending(candidate.site, candidate.page_id)
        {:ok, :ok}
      end)

    :ok
  end

  @doc "Records a failed fetch of `candidate` at `now`; it is left alone until `Knowseek.Crawl`'s `retry_minutes` have passed."
  @spec mark_failed(Candidate.t(), DateTime.t()) :: :ok
  def mark_failed(candidate, now) do
    Repo.update_all(row(candidate), set: [failed_at: now])
    :ok
  end

  @doc "Deletes the `pending` row of `candidate`."
  @spec delete(Candidate.t()) :: :ok
  def delete(candidate) do
    Repo.delete_all(from c in row(candidate), where: c.state == "pending")
    :ok
  end

  @doc "Deletes every `pending` row of the page `page_id` of `site`."
  @spec delete_page(String.t(), integer()) :: :ok
  def delete_page(site, page_id) do
    delete_pending(site, page_id)
    :ok
  end

  defp delete_pending(site, page_id) do
    Repo.delete_all(
      from c in Candidate,
        where: c.site == ^site and c.page_id == ^page_id and c.state == "pending"
    )
  end

  defp row(candidate) do
    from c in Candidate,
      where:
        c.source_document_id == ^candidate.source_document_id and c.page_id == ^candidate.page_id
  end

  @doc "The counters for `/stats`: links read, pending candidates, fetched candidates and their stored bytes."
  @spec totals() :: %{
          links_read: non_neg_integer(),
          candidates: non_neg_integer(),
          fetched: non_neg_integer(),
          stored_bytes: non_neg_integer()
        }
  def totals do
    links_read = Repo.one(from s in SourcePage, select: coalesce(sum(s.links), 0))

    {candidates, fetched, stored_bytes} =
      Repo.one(
        from c in Candidate,
          select: {
            fragment("coalesce(sum(? = 'pending'), 0)", c.state),
            fragment("coalesce(sum(? = 'fetched'), 0)", c.state),
            coalesce(sum(c.stored_bytes), 0)
          }
      )

    %{
      links_read: links_read,
      candidates: candidates,
      fetched: fetched,
      stored_bytes: stored_bytes
    }
  end

  @doc """
  Deletes the `crawl_sources` rows and the `pending` candidates whose source
  page is not in `source_ids`. `fetched` and `skipped` rows stay.
  """
  @spec prune([Ecto.UUID.t()]) :: :ok
  def prune(source_ids) do
    keep = MapSet.new(source_ids)

    stale =
      Repo.all(from s in SourcePage, select: s.document_id)
      |> Enum.concat(
        Repo.all(
          from c in Candidate,
            where: c.state == "pending",
            distinct: true,
            select: c.source_document_id
        )
      )
      |> Enum.reject(&MapSet.member?(keep, &1))
      |> Enum.uniq()

    for chunk <- Enum.chunk_every(stale, @chunk) do
      {:ok, :ok} =
        Repo.transact(fn ->
          Repo.delete_all(from s in SourcePage, where: s.document_id in ^chunk)

          Repo.delete_all(
            from c in Candidate, where: c.state == "pending" and c.source_document_id in ^chunk
          )

          {:ok, :ok}
        end)
    end

    :ok
  end

  @doc "Deletes every `crawl_sources` row and every `pending` candidate. Returns the number of candidates deleted."
  @spec clear_pending() :: {:ok, non_neg_integer()}
  def clear_pending do
    Repo.transact(fn ->
      Repo.delete_all(SourcePage)
      {deleted, _rows} = Repo.delete_all(from c in Candidate, where: c.state == "pending")
      {:ok, deleted}
    end)
  end
end
