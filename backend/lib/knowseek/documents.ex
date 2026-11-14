defmodule Knowseek.Documents do
  @moduledoc """
  Stores documents in the search index.

  `ingest/1` is the single write path: it canonicalizes the URL, finds the
  document the content belongs to (or none), splits new content into chunks,
  embeds the chunks, and stores everything in one transaction.
  """
  import Ecto.Query

  alias Knowseek.Documents.{Chunk, Chunker, ChunkVector, Document, DocumentAlias}
  alias Knowseek.Embeddings
  alias Knowseek.Repo

  # A body shorter than this (in characters, after trimming) is never matched
  # by content hash alone. "Not found" pages, cookie banners, and stubs repeat
  # across unrelated URLs, and merging them would hide real pages.
  @min_alias_body_length 200

  @doc "The shortest body (in characters) that is merged with another URL's document by content."
  @spec min_alias_body_length() :: pos_integer()
  def min_alias_body_length, do: @min_alias_body_length

  @doc """
  Adds a document to the index, or updates the document it belongs to.

  The URL is canonicalized first (`Knowseek.Documents.URL`). The document is:

  1. the one whose `url` equals the canonical URL. A changed body re-chunks
     and re-embeds it. Else
  2. the one that has the canonical URL as an alias. If the body is the same,
     only `fetched_at` moves. If the body differs, the page is no longer a copy:
     the alias is deleted and the URL is handled as a new one (step 3 or 4).
     Else
  3. when the body is at least `min_alias_body_length/0` characters, the
     oldest document with the same body. Only its `fetched_at` moves, and the
     canonical URL is recorded as its alias. If that document has only a URL
     generated from the body, the canonical URL becomes its `url` instead,
     and there is no alias. Else
  4. a new document.

  Required attrs: `:body`, `:source`. Optional: `:url`, `:title`,
  `:published_at`, `:fetched_at`, `:metadata`, `:monthly_views` (a
  non-negative integer), `:source_updated_at` (when the source says the page
  was last edited), and the license fields `:license`, `:attribution` (a map
  with `:url`, `:credit`, `:authors`), `:modified`, `:share` (ADR 0026). An
  attr that is left out keeps the stored value, so a source that has no figure
  this time does not erase an earlier one. A new document without the license
  fields gets `LicenseRef-unknown`, no attribution, `false` and `none`; an
  explicit `nil` for `:license`, `:modified` or `:share` is an error.
  A document that is only touched (the URL is an alias, or the body is the
  copy of another document's) keeps the original's `monthly_views`,
  `source_updated_at` and license fields.

  `:origin` (`"search"`, `"background"` or `"manual"`) and `:origin_query`
  (the normalized query, for `"search"`) are optional too, and write-once
  (#96, ADR 0031): a new document without them is `manual`, and for a
  document that exists (found by URL, by alias or by content) they are
  ignored, because the origin says why the page first entered the index. A
  background page stays `background` when a later search fetches it again.

  If the stored document found by its own URL already has the same body,
  nothing is re-chunked or re-embedded. The other fields are still updated,
  and `fetched_at` moves to now (unless the caller gives one), because the
  fetch saw the content.
  """
  @spec ingest(map()) :: {:ok, Document.t()} | {:error, Ecto.Changeset.t() | term()}
  def ingest(attrs) do
    changeset = Document.ingest_changeset(%Document{}, attrs)

    with {:ok, incoming} <- Ecto.Changeset.apply_action(changeset, :insert) do
      dispatch(incoming, attrs)
    end
  end

  defp dispatch(incoming, attrs) do
    case locate(incoming) do
      {:url, %Document{content_hash: hash} = existing} when hash == incoming.content_hash ->
        existing |> Document.ingest_changeset(attrs) |> Repo.update()

      {:url, existing} ->
        store(existing, attrs, incoming.body)

      {:alias, %Document{content_hash: hash} = existing, _alias}
      when hash == incoming.content_hash ->
        touch(existing, incoming)

      {:alias, _existing, stale} ->
        # The alias URL now serves something else. Drop the alias and start over.
        Repo.delete!(stale)
        dispatch(incoming, attrs)

      {:same_content, existing} ->
        merge(existing, incoming)

      :new ->
        store(nil, attrs, incoming.body)
    end
  end

  # `incoming.url` is already canonical. A document found by its own URL or by
  # an alias wins over one found by content.
  defp locate(%Document{url: url, body: body, content_hash: hash}) do
    cond do
      document = Repo.get_by(Document, url: url) -> {:url, document}
      match = get_by_alias(url) -> {:alias, elem(match, 0), elem(match, 1)}
      document = long_enough?(body) && get_by_content_hash(hash) -> {:same_content, document}
      true -> :new
    end
  end

  defp get_by_alias(url) do
    Repo.one(
      from a in DocumentAlias,
        join: d in assoc(a, :document),
        where: a.url == ^url,
        select: {d, a}
    )
  end

  # Oldest first, so concurrent duplicates all merge into the same document.
  defp get_by_content_hash(hash) do
    Repo.one(
      from d in Document,
        where: d.content_hash == ^hash,
        order_by: [asc: d.inserted_at, asc: d.id],
        limit: 1
    )
  end

  defp long_enough?(body), do: String.length(String.trim(body)) >= @min_alias_body_length

  # `existing` has the same body as `incoming` but is known under another URL.
  # There is nothing to chunk or embed. The incoming fields (source, title,
  # metadata) describe the copy, so they never overwrite the original's.
  defp merge(existing, incoming) do
    cond do
      Document.content_url?(incoming.url) -> touch(existing, incoming)
      Document.content_url?(existing.url) -> adopt_url(existing, incoming)
      true -> add_alias(existing, incoming)
    end
  end

  # A body stored without a URL gets the first real URL it is seen under. If
  # a concurrent ingest took that URL first, keep it as an alias instead.
  defp adopt_url(existing, incoming) do
    existing
    |> Ecto.Changeset.change(url: incoming.url, fetched_at: incoming.fetched_at)
    |> Ecto.Changeset.unique_constraint(:url)
    |> Repo.update()
    |> case do
      {:error, %Ecto.Changeset{errors: [url: _]}} -> add_alias(existing, incoming)
      result -> result
    end
  end

  defp touch(existing, incoming),
    do: existing |> Ecto.Changeset.change(fetched_at: incoming.fetched_at) |> Repo.update()

  # The alias and the `fetched_at` update commit together. A concurrent ingest
  # can insert the same alias first; `on_conflict: :nothing` keeps that row.
  defp add_alias(existing, incoming) do
    Repo.transact(fn ->
      with {:ok, document} <- touch(existing, incoming),
           {:ok, _alias} <-
             %DocumentAlias{}
             |> DocumentAlias.changeset(%{url: incoming.url, document_id: document.id})
             |> Repo.insert(on_conflict: :nothing, conflict_target: :url) do
        {:ok, document}
      end
    end)
  end

  defp store(existing, attrs, body) do
    contents = Chunker.chunk(body)

    # Embed before the transaction: the adapter may call an external API.
    with {:ok, vectors} <- Embeddings.embed(contents, input_type: :document) do
      Repo.transact(fn -> write(existing, attrs, Enum.zip(contents, vectors)) end)
    end
  end

  defp write(existing, attrs, contents_and_vectors) do
    with {:ok, document} <- upsert_document(existing, attrs) do
      replace_chunks(document, contents_and_vectors)
      {:ok, document}
    end
  end

  # A concurrent ingest of the same URL can insert between `locate/1` and
  # here. On conflict, update that row instead of failing on the unique index.
  defp upsert_document(nil, attrs) do
    %Document{}
    |> Document.ingest_changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at, :origin, :origin_query]},
      conflict_target: :url,
      returning: true
    )
  end

  defp upsert_document(%Document{} = existing, attrs),
    do: existing |> Document.ingest_changeset(attrs) |> Repo.update()

  # Deleting the old chunks also deletes their full-text and vector rows
  # (triggers on `chunks`). The new chunks get their `seq` from SQLite, and
  # their vectors are stored under it. RETURNING has no defined row order, so
  # the rows are matched by position.
  defp replace_chunks(document, contents_and_vectors) do
    Repo.delete_all(from c in Chunk, where: c.document_id == ^document.id)
    now = DateTime.utc_now(:second)
    indexed = Enum.with_index(contents_and_vectors)

    rows =
      Enum.map(indexed, fn {{content, _vector}, position} ->
        %{
          document_id: document.id,
          position: position,
          content: content,
          inserted_at: now,
          updated_at: now
        }
      end)

    {_count, inserted} = Repo.insert_all(Chunk, rows, returning: [:seq, :position])
    seq_at = Map.new(inserted, &{&1.position, &1.seq})

    vectors =
      Enum.map(indexed, fn {{_content, vector}, position} ->
        %{rowid: Map.fetch!(seq_at, position), embedding: vector}
      end)

    Repo.insert_all(ChunkVector, vectors)
  end

  @spec get_document(Ecto.UUID.t()) :: Document.t() | nil
  def get_document(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Document, uuid)
      :error -> nil
    end
  end

  @doc """
  The most recently fetched documents, newest first.

  The documents have no `body` (it is `nil`), because bodies can be large and
  a list does not need them. Use `get_document/1` to read one in full.
  """
  @spec list_documents(keyword()) :: [Document.t()]
  def list_documents(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Repo.all(
      from d in Document,
        order_by: [desc: d.fetched_at],
        limit: ^limit,
        select: %{d | body: nil}
    )
  end

  @doc "How many documents each origin has."
  @spec count_by_origin() :: %{
          search: non_neg_integer(),
          background: non_neg_integer(),
          manual: non_neg_integer()
        }
  def count_by_origin do
    counts =
      Repo.all(from d in Document, group_by: d.origin, select: {d.origin, count()}) |> Map.new()

    %{
      search: Map.get(counts, "search", 0),
      background: Map.get(counts, "background", 0),
      manual: Map.get(counts, "manual", 0)
    }
  end

  @doc "The ids of the documents whose `source` is one of `sources`, oldest first."
  @spec ids_by_source([String.t()]) :: [Ecto.UUID.t()]
  def ids_by_source(sources) do
    Repo.all(
      from d in Document,
        where: d.source in ^sources,
        order_by: [asc: d.inserted_at, asc: d.id],
        select: d.id
    )
  end

  @doc """
  Which of `page_ids` are the `pageid` (in `metadata`) of a stored document
  of `source`. Reads the index `documents_source_pageid_index`, not the rows.
  """
  @spec indexed_page_ids(String.t(), [integer()]) :: MapSet.t(integer())
  def indexed_page_ids(_source, []), do: MapSet.new()

  def indexed_page_ids(source, page_ids) do
    page_ids
    |> Enum.chunk_every(500)
    |> Enum.flat_map(fn chunk ->
      Repo.all(
        from d in Document,
          where:
            d.source == ^source and
              fragment("json_extract(?, '$.pageid')", d.metadata) in ^chunk,
          select: fragment("json_extract(?, '$.pageid')", d.metadata)
      )
    end)
    |> MapSet.new()
  end

  @doc "The title and URL of each of `ids` that exists. No bodies are read."
  @spec summaries([Ecto.UUID.t()]) :: %{
          Ecto.UUID.t() => %{title: String.t() | nil, url: String.t()}
        }
  def summaries([]), do: %{}

  def summaries(ids) do
    ids
    |> Enum.chunk_every(500)
    |> Enum.flat_map(fn chunk ->
      Repo.all(
        from d in Document,
          where: d.id in ^chunk,
          select: {d.id, %{title: d.title, url: d.url}}
      )
    end)
    |> Map.new()
  end

  @doc """
  An estimate of the bytes document `id` takes: its body, its chunks' text and
  4 bytes per vector dimension per chunk. The full-text index and row
  overhead are not counted. 0 for an unknown id.
  """
  @spec stored_bytes(Ecto.UUID.t()) :: non_neg_integer()
  def stored_bytes(id) do
    body =
      Repo.one(
        from d in Document,
          where: d.id == ^id,
          select: fragment("length(CAST(? AS BLOB))", d.body)
      ) || 0

    {text, chunks} =
      Repo.one(
        from c in Chunk,
          where: c.document_id == ^id,
          select: {coalesce(sum(fragment("length(CAST(? AS BLOB))", c.content)), 0), count()}
      )

    body + text + chunks * 4 * Embeddings.dimensions()
  end
end
