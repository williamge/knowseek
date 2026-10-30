defmodule Knowseek.DocumentsTest do
  use Knowseek.DataCase, async: true

  alias Knowseek.Documents
  alias Knowseek.Documents.{Chunk, Document}

  describe "ingest/1" do
    test "stores the document with embedded chunks" do
      {:ok, document} =
        Documents.ingest(%{
          url: "https://example.com/a",
          title: "A",
          body: "First paragraph.\n\nSecond paragraph.",
          source: "test"
        })

      assert document.content_hash == Document.hash_body("First paragraph.\n\nSecond paragraph.")
      assert [%Chunk{position: 0, embedding: embedding}] = chunks(document)
      assert embedding |> Pgvector.to_list() |> length() == Knowseek.Embeddings.dimensions()
    end

    test "generates a URL when none is given" do
      {:ok, document} = Documents.ingest(%{body: "No url here.", source: "test"})
      assert "urn:knowseek:sha256:" <> _ = document.url
    end

    test "updates the existing document and its chunks when the body changes" do
      original = document_fixture(url: "https://example.com/b", body: "old body")

      {:ok, updated} =
        Documents.ingest(%{url: "https://example.com/b", body: "new body", source: "test"})

      assert updated.id == original.id
      assert updated.body == "new body"
      assert [%Chunk{content: "new body"}] = chunks(updated)
    end

    test "refreshes fetched_at when the body changes" do
      old = ~U[2020-01-01 00:00:00Z]
      document_fixture(url: "https://example.com/f", body: "old body", fetched_at: old)

      {:ok, updated} =
        Documents.ingest(%{url: "https://example.com/f", body: "new body", source: "test"})

      assert DateTime.compare(updated.fetched_at, old) == :gt
    end

    test "moves fetched_at forward when the body is unchanged" do
      old = ~U[2020-01-01 00:00:00Z]
      original = document_fixture(url: "https://example.com/g", body: "same", fetched_at: old)
      [chunk] = chunks(original)

      {:ok, again} =
        Documents.ingest(%{url: "https://example.com/g", body: "same", source: "test"})

      assert DateTime.compare(again.fetched_at, old) == :gt
      assert DateTime.compare(Documents.get_document(original.id).fetched_at, old) == :gt
      assert [%Chunk{id: id}] = chunks(again)
      assert id == chunk.id
    end

    test "updates the other fields when the body is unchanged" do
      published = ~U[2020-01-01 00:00:00Z]
      original = document_fixture(url: "https://example.com/h", title: "Old", body: "same")

      {:ok, again} =
        Documents.ingest(%{
          url: "https://example.com/h",
          title: "New",
          body: "same",
          source: "test",
          published_at: published
        })

      assert %Document{title: "New", published_at: ^published} =
               Documents.get_document(original.id)

      assert again.id == original.id
    end

    test "does not rewrite an unchanged document" do
      original = document_fixture(url: "https://example.com/c", body: "same")
      [chunk] = chunks(original)

      {:ok, again} =
        Documents.ingest(%{url: "https://example.com/c", body: "same", source: "test"})

      assert again.id == original.id
      assert [%Chunk{id: id}] = chunks(again)
      assert id == chunk.id
    end

    test "rejects a document without a body" do
      assert {:error, changeset} =
               Documents.ingest(%{url: "https://example.com/d", source: "test"})

      assert %{body: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "get_document/1" do
    test "returns nil for an unknown or invalid id" do
      assert Documents.get_document(Ecto.UUID.generate()) == nil
      assert Documents.get_document("not-a-uuid") == nil
    end
  end

  defp chunks(document),
    do: Repo.all(from c in Chunk, where: c.document_id == ^document.id, order_by: c.position)
end
