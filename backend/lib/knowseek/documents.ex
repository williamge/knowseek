defmodule Knowseek.Documents do
  @moduledoc """
  Stores documents in the search index.

  `ingest/1` is the single write path: it canonicalizes the URL, finds the
  document the content belongs to (or none), splits new content into chunks,
  embeds the chunks, and stores everything in one transaction.
  """
  import Ecto.Query

  alias Knowseek.Documents.{Chunk, Chunker, Document, DocumentAlias}
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

  1. the one whose `url` or alias URL equals the canonical URL, else
  2. when the body is at least `min_alias_body_length/0` characters, the
     oldest document with the same body. The canonical URL is then recorded
     as an alias of that document, and that document is returned. Else
  3. a new document.

  A document keeps its own `url`. Ingesting through an alias never changes it.

  If the stored document already has the same body, nothing is re-chunked
  or re-embedded. The other fields are still updated, and `fetched_at` moves
  to now (unless the caller gives one), because the fetch saw the content.

  Required attrs: `:body`, `:source`. Optional: `:url`, `:title`,
  `:published_at`, `:fetched_at`, `:metadata`.
  """
  @spec ingest(map()) :: {:ok, Document.t()} | {:error, Ecto.Changeset.t() | term()}
  def ingest(attrs) do
    changeset = Document.ingest_changeset(%Document{}, attrs)

    with {:ok, incoming} <- Ecto.Changeset.apply_action(changeset, :insert) do
      case locate(incoming) do
        {:known, %Document{content_hash: hash} = existing} when hash == incoming.content_hash ->
          existing |> existing_changeset(attrs) |> Repo.update()

        {:known, existing} ->
          store(existing, attrs, incoming.body)

        {:same_content, existing} ->
          merge(existing, attrs, incoming.url)

        :new ->
          store(nil, attrs, incoming.body)
      end
    end
  end

  # `incoming.url` is already canonical. A document found by its own URL or by
  # an alias wins over one found by content.
  defp locate(%Document{url: url, body: body, content_hash: hash}) do
    cond do
      document = get_by_url_or_alias(url) -> {:known, document}
      document = long_enough?(body) && get_by_content_hash(hash) -> {:same_content, document}
      true -> :new
    end
  end

  defp get_by_url_or_alias(url) do
    Repo.get_by(Document, url: url) ||
      Repo.one(
        from d in Document,
          join: a in DocumentAlias,
          on: a.document_id == d.id,
          where: a.url == ^url
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

  # Same body as `existing`, found under a different URL: no chunks to write.
  # The alias and the document update commit together. A URL generated from
  # the body is no alias: the body already implies it.
  defp merge(existing, attrs, url) do
    Repo.transact(fn ->
      with {:ok, document} <- existing |> existing_changeset(attrs) |> Repo.update() do
        add_alias(document, url)
      end
    end)
  end

  # A concurrent ingest can insert the same alias first; keep that row.
  defp add_alias(document, url) do
    if Document.content_url?(url), do: {:ok, document}, else: insert_alias(document, url)
  end

  defp insert_alias(document, url) do
    with {:ok, _alias} <-
           %DocumentAlias{}
           |> DocumentAlias.changeset(%{url: url, document_id: document.id})
           |> Repo.insert(on_conflict: :nothing, conflict_target: :url) do
      {:ok, document}
    end
  end

  # The caller's URL may be an alias: the stored document keeps its own.
  defp existing_changeset(%Document{} = existing, attrs) do
    existing |> Document.ingest_changeset(attrs) |> Ecto.Changeset.put_change(:url, existing.url)
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
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: :url,
      returning: true
    )
  end

  defp upsert_document(%Document{} = existing, attrs),
    do: existing |> existing_changeset(attrs) |> Repo.update()

  defp replace_chunks(document, contents_and_vectors) do
    Repo.delete_all(from c in Chunk, where: c.document_id == ^document.id)
    now = DateTime.utc_now(:second)

    rows =
      contents_and_vectors
      |> Enum.with_index()
      |> Enum.map(fn {{content, vector}, position} ->
        %{
          document_id: document.id,
          position: position,
          content: content,
          embedding: Pgvector.new(vector),
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(Chunk, rows)
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
end
