defmodule Knowseek.Documents do
  @moduledoc """
  Stores documents in the search index.

  `ingest/1` is the single write path: it validates a document, splits it
  into chunks, embeds the chunks, and stores everything in one transaction.
  """
  import Ecto.Query

  alias Knowseek.Documents.{Chunk, Chunker, Document}
  alias Knowseek.Embeddings
  alias Knowseek.Repo

  @doc """
  Adds a document to the index, or updates the document with the same URL.

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
      case Repo.get_by(Document, url: incoming.url) do
        %Document{content_hash: hash} = existing when hash == incoming.content_hash ->
          existing |> Document.ingest_changeset(attrs) |> Repo.update()

        existing ->
          store(existing, attrs, incoming.body)
      end
    end
  end

  defp store(existing, attrs, body) do
    contents = Chunker.chunk(body)

    # Embed before the transaction: the adapter may call an external API.
    with {:ok, vectors} <- Embeddings.embed(contents) do
      Repo.transact(fn -> write(existing, attrs, Enum.zip(contents, vectors)) end)
    end
  end

  defp write(existing, attrs, contents_and_vectors) do
    with {:ok, document} <- upsert_document(existing, attrs) do
      replace_chunks(document, contents_and_vectors)
      {:ok, document}
    end
  end

  # A concurrent ingest of the same URL can insert between `Repo.get_by/2` and
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
    do: existing |> Document.ingest_changeset(attrs) |> Repo.update()

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

  @spec list_documents(keyword()) :: [Document.t()]
  def list_documents(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    Repo.all(from d in Document, order_by: [desc: d.fetched_at], limit: ^limit)
  end
end
