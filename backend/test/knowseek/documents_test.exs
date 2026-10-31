defmodule Knowseek.DocumentsTest do
  use Knowseek.DataCase, async: true

  alias Knowseek.Documents
  alias Knowseek.Documents.{Chunk, Document, DocumentAlias}

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

  describe "ingest/1 URL canonicalization" do
    test "stores the canonical URL" do
      {:ok, document} =
        Documents.ingest(%{
          url: "HTTPS://Example.COM:443/a?utm_source=x&b=2&a=1#top",
          body: "Canonical.",
          source: "test"
        })

      assert document.url == "https://example.com/a?a=1&b=2"
    end

    test "variants of one URL give one document" do
      body = long_body("variants")

      variants = [
        "https://example.com/page?id=1",
        "HTTPS://EXAMPLE.com/page?id=1",
        "https://example.com:443/page?id=1",
        "https://example.com/page?id=1#section",
        "https://example.com/page?utm_source=news&utm_medium=email&id=1",
        "https://example.com/page?id=1&fbclid=abc"
      ]

      ids =
        for url <- variants do
          {:ok, document} = Documents.ingest(%{url: url, body: body, source: "test"})
          document.id
        end

      assert [_] = Enum.uniq(ids)
      assert Repo.aggregate(Document, :count) == 1
      assert Repo.aggregate(DocumentAlias, :count) == 0
    end

    test "variants of one URL give one document even for a short body" do
      {:ok, first} = Documents.ingest(%{url: "http://Example.com:80", body: "x", source: "test"})

      {:ok, second} =
        Documents.ingest(%{url: "http://example.com/?utm_campaign=y", body: "x", source: "test"})

      assert first.id == second.id
    end
  end

  describe "ingest/1 duplicate content" do
    test "the same body under two URLs gives one document with an alias" do
      body = long_body("dup")

      {:ok, first} =
        Documents.ingest(%{url: "https://a.example/post", body: body, source: "test"})

      {:ok, second} =
        Documents.ingest(%{url: "https://b.example/copy", body: body, source: "test"})

      assert second.id == first.id
      assert second.url == "https://a.example/post"
      assert Repo.aggregate(Document, :count) == 1
      assert alias_urls(first) == ["https://b.example/copy"]
      assert [%Chunk{}] = chunks(first)
    end

    test "ingesting by the alias URL updates the same document and keeps its URL" do
      body = long_body("alias")

      {:ok, first} =
        Documents.ingest(%{url: "https://a.example/post", body: body, source: "test"})

      {:ok, _} = Documents.ingest(%{url: "https://b.example/copy", body: body, source: "test"})

      {:ok, again} =
        Documents.ingest(%{
          url: "https://b.example/copy?utm_source=x",
          title: "Via alias",
          body: body,
          source: "test"
        })

      assert again.id == first.id
      assert again.url == "https://a.example/post"

      assert %Document{title: "Via alias", url: "https://a.example/post"} =
               Documents.get_document(first.id)

      assert Repo.aggregate(Document, :count) == 1
      assert alias_urls(first) == ["https://b.example/copy"]
    end

    test "a changed body through an alias URL rewrites the aliased document" do
      body = long_body("changed")

      {:ok, first} =
        Documents.ingest(%{url: "https://a.example/post", body: body, source: "test"})

      {:ok, _} = Documents.ingest(%{url: "https://b.example/copy", body: body, source: "test"})

      new_body = long_body("changed again")

      {:ok, updated} =
        Documents.ingest(%{url: "https://b.example/copy", body: new_body, source: "test"})

      assert updated.id == first.id
      assert updated.url == "https://a.example/post"
      assert updated.body == new_body
      assert [%Chunk{content: content}] = chunks(updated)
      assert content == String.trim(new_body)
      assert Repo.aggregate(Document, :count) == 1
    end

    test "a repeated ingest does not duplicate the alias" do
      body = long_body("twice")

      {:ok, first} =
        Documents.ingest(%{url: "https://a.example/post", body: body, source: "test"})

      for _ <- 1..2 do
        {:ok, _} = Documents.ingest(%{url: "https://b.example/copy", body: body, source: "test"})
      end

      assert alias_urls(first) == ["https://b.example/copy"]
    end

    test "a second copy merges into the oldest document" do
      body = long_body("oldest")
      {:ok, first} = Documents.ingest(%{url: "https://a.example/1", body: body, source: "test"})
      {:ok, _} = Documents.ingest(%{url: "https://b.example/2", body: body, source: "test"})
      {:ok, third} = Documents.ingest(%{url: "https://c.example/3", body: body, source: "test"})

      assert third.id == first.id
      assert alias_urls(first) == ["https://b.example/2", "https://c.example/3"]
    end

    test "does not merge a short body found under two URLs" do
      body = "Page not found."

      {:ok, first} =
        Documents.ingest(%{url: "https://a.example/missing", body: body, source: "t"})

      {:ok, second} = Documents.ingest(%{url: "https://b.example/gone", body: body, source: "t"})

      refute first.id == second.id
      assert Repo.aggregate(DocumentAlias, :count) == 0
    end

    test "the length floor counts characters, not bytes, and ignores padding" do
      floor = Documents.min_alias_body_length()
      at_floor = String.duplicate("é", floor)
      below = String.duplicate("é", floor - 1)
      padded = "  " <> below <> "\n\n"

      {:ok, a} = Documents.ingest(%{url: "https://a.example/1", body: at_floor, source: "t"})
      {:ok, b} = Documents.ingest(%{url: "https://b.example/1", body: at_floor, source: "t"})
      assert a.id == b.id

      for body <- [below, padded] do
        {:ok, c} =
          Documents.ingest(%{
            url: "https://a.example/#{byte_size(body)}",
            body: body,
            source: "t"
          })

        {:ok, d} =
          Documents.ingest(%{
            url: "https://b.example/#{byte_size(body)}",
            body: body,
            source: "t"
          })

        refute c.id == d.id
      end
    end

    test "a document with the same body but no URL returns the existing document" do
      body = long_body("nourl")

      {:ok, first} =
        Documents.ingest(%{url: "https://a.example/post", body: body, source: "test"})

      {:ok, second} = Documents.ingest(%{body: body, source: "test"})

      assert second.id == first.id
      assert Repo.aggregate(DocumentAlias, :count) == 0
    end

    test "a real URL for a body first stored without a URL becomes its alias" do
      body = long_body("urnfirst")
      {:ok, first} = Documents.ingest(%{body: body, source: "test"})

      {:ok, second} =
        Documents.ingest(%{url: "https://a.example/post", body: body, source: "test"})

      assert second.id == first.id
      assert "urn:knowseek:sha256:" <> _ = second.url
      assert alias_urls(first) == ["https://a.example/post"]
    end

    test "different bodies under different URLs stay separate documents" do
      {:ok, a} = Documents.ingest(%{url: "https://a.example", body: long_body("x"), source: "t"})
      {:ok, b} = Documents.ingest(%{url: "https://b.example", body: long_body("y"), source: "t"})

      refute a.id == b.id
    end

    test "deleting a document deletes its aliases" do
      body = long_body("cascade")

      {:ok, first} =
        Documents.ingest(%{url: "https://a.example/post", body: body, source: "test"})

      {:ok, _} = Documents.ingest(%{url: "https://b.example/copy", body: body, source: "test"})

      Repo.delete!(first)

      assert Repo.aggregate(DocumentAlias, :count) == 0
    end
  end

  describe "get_document/1" do
    test "returns nil for an unknown or invalid id" do
      assert Documents.get_document(Ecto.UUID.generate()) == nil
      assert Documents.get_document("not-a-uuid") == nil
    end
  end

  describe "list_documents/1" do
    test "returns the newest documents first, without their bodies" do
      old = document_fixture(body: "Old note.", fetched_at: ~U[2020-01-01 00:00:00Z])
      new = document_fixture(body: "New note.", fetched_at: ~U[2026-01-01 00:00:00Z])

      assert [%{id: new_id, body: nil}, %{id: old_id, body: nil}] = Documents.list_documents()
      assert {new_id, old_id} == {new.id, old.id}
    end

    test "respects :limit" do
      for i <- 1..3, do: document_fixture(body: "Note #{i}.")
      assert length(Documents.list_documents(limit: 2)) == 2
    end
  end

  defp alias_urls(document) do
    Repo.all(
      from a in DocumentAlias,
        where: a.document_id == ^document.id,
        order_by: a.inserted_at,
        select: a.url
    )
    |> Enum.sort()
  end

  defp chunks(document),
    do: Repo.all(from c in Chunk, where: c.document_id == ^document.id, order_by: c.position)
end
