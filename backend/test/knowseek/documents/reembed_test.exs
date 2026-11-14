defmodule Knowseek.Documents.ReembedTest do
  use Knowseek.DataCase, async: false

  alias Knowseek.Documents
  alias Knowseek.Documents.{Chunk, Document, EmbeddingModel}
  alias Knowseek.Embeddings

  # One chunk per paragraph: 900 characters each.
  defp pages(words), do: Enum.map_join(words, "\n\n", &String.duplicate("#{&1} ", 150))

  defp use_hook_adapter(hook) do
    config = Application.fetch_env!(:knowseek, Embeddings)

    Application.put_env(
      :knowseek,
      Embeddings,
      Keyword.put(config, :adapter, Embeddings.HookAdapter)
    )

    Application.put_env(:knowseek, Embeddings.HookAdapter, hook: hook)

    on_exit(fn ->
      Application.put_env(:knowseek, Embeddings, config)
      Application.delete_env(:knowseek, Embeddings.HookAdapter)
    end)
  end

  defp snapshot do
    %{
      chunks:
        Repo.all(from c in Chunk, order_by: c.seq, select: {c.seq, c.id, c.position, c.content}),
      fts: Repo.query!("SELECT count(*) FROM chunks_fts_docsize").rows,
      vectors: Repo.query!("SELECT count(*) FROM chunk_vectors").rows
    }
  end

  describe "reembed_stale/1" do
    test "gives every stale page the new model's vectors, and touches nothing else" do
      a = document_fixture(body: pages(~w(alpha bravo)))
      b = document_fixture(body: pages(~w(charlie)))
      c = document_fixture(body: "short")
      old_id = a.embedding_model_id
      before = snapshot()
      updated_at = Repo.all(from d in Document, order_by: d.id, select: {d.id, d.updated_at})

      switch_embedding_model(2)
      assert Documents.reembedding?()

      assert {:ok, %{documents: 3, more?: false}} = Documents.reembed_stale()

      {:ok, new_id} = Documents.current_model_id()
      assert new_id != old_id

      for document <- [a, b, c] do
        assert Repo.reload!(document).embedding_model_id == new_id
        assert Enum.all?(vector_model_ids(document), &(&1 == new_id))

        for chunk <- Repo.all(from ch in Chunk, where: ch.document_id == ^document.id) do
          {:ok, [vector]} = Embeddings.embed([chunk.content], input_type: :document)

          assert chunk_embedding(chunk) ==
                   vector |> Documents.Vector.encode() |> Documents.Vector.decode()
        end
      end

      # The same chunk ids, seq and positions, and the same row counts.
      assert snapshot() == before

      assert Repo.all(from d in Document, order_by: d.id, select: {d.id, d.updated_at}) ==
               updated_at

      refute Documents.reembedding?()
    end

    test "works in storage order, with :limit and more?" do
      docs = for i <- 1..3, do: document_fixture(body: "page number #{i}")
      switch_embedding_model(2)

      assert {:ok, %{documents: 2, more?: true}} = Documents.reembed_stale(limit: 2)

      {:ok, new_id} = Documents.current_model_id()
      [first, second, third] = Enum.map(docs, &Repo.reload!/1)
      assert first.embedding_model_id == new_id
      assert second.embedding_model_id == new_id
      assert third.embedding_model_id != new_id

      assert {:ok, %{documents: 1, more?: false}} = Documents.reembed_stale(limit: 2)
      assert Repo.reload!(third).embedding_model_id == new_id
    end

    test "re-embeds the page whose first passage is oldest first" do
      old = document_fixture(body: "old page")
      new = document_fixture(body: "new page")
      switch_embedding_model(2)

      assert {:ok, %{documents: 1, more?: true}} = Documents.reembed_stale(limit: 1)

      {:ok, new_id} = Documents.current_model_id()
      assert Repo.reload!(old).embedding_model_id == new_id
      assert Repo.reload!(new).embedding_model_id != new_id
    end

    test "embeds in requests of batch_size passages" do
      test_pid = self()
      use_hook_adapter(fn texts -> send(test_pid, {:embed, length(texts)}) end)

      document_fixture(body: pages(~w(alpha bravo charlie delta echo foxtrot)))
      assert_received {:embed, 6}
      switch_embedding_model(2)

      assert {:ok, %{documents: 1}} = Documents.reembed_stale()
      assert_received {:embed, 4}
      assert_received {:embed, 2}
    end

    test "a failed embedding returns the error and leaves the remaining pages stale" do
      first = document_fixture(body: "fine page")
      second = document_fixture(body: "boom page")
      third = document_fixture(body: "another fine page")

      use_hook_adapter(fn texts ->
        if Enum.any?(texts, &String.contains?(&1, "boom")), do: {:error, :boom}
      end)

      switch_embedding_model(2)

      assert {:error, :boom} = Documents.reembed_stale()

      {:ok, new_id} = Documents.current_model_id()
      assert Repo.reload!(first).embedding_model_id == new_id
      assert Repo.reload!(second).embedding_model_id != new_id
      assert Repo.reload!(third).embedding_model_id != new_id
      assert Documents.reembedding?()
    end

    test "skips a page whose passages were replaced between the read and the write" do
      page = document_fixture(url: "https://example.com/race", body: "original text")
      switch_embedding_model(2)

      # The concurrent ingest happens while the re-embed's embedding call runs.
      use_hook_adapter(fn _texts ->
        Application.put_env(:knowseek, Embeddings.HookAdapter, [])

        {:ok, _} =
          Documents.ingest(%{url: page.url, body: "replaced text", source: "test"})

        :ok
      end)

      assert {:ok, %{documents: 1}} = Documents.reembed_stale()

      {:ok, new_id} = Documents.current_model_id()
      reloaded = Repo.reload!(page)
      assert reloaded.body == "replaced text"
      assert reloaded.embedding_model_id == new_id
      assert vector_model_ids(reloaded) == [new_id]

      assert [%Chunk{content: "replaced text"}] =
               Repo.all(from c in Chunk, where: c.document_id == ^page.id)

      assert snapshot().fts == snapshot().vectors
    end

    test "only stamps a page without passages" do
      page = document_fixture(body: "text")
      Repo.delete_all(from c in Chunk, where: c.document_id == ^page.id)
      switch_embedding_model(2)

      assert {:ok, %{documents: 1, more?: false}} = Documents.reembed_stale()

      {:ok, new_id} = Documents.current_model_id()
      assert Repo.reload!(page).embedding_model_id == new_id
    end

    test "deletes the model rows that no page uses, and keeps the current one" do
      document_fixture()
      switch_embedding_model(2)
      assert Repo.aggregate(EmbeddingModel, :count) == 1

      assert {:ok, %{more?: false}} = Documents.reembed_stale()

      {:ok, new_id} = Documents.current_model_id()
      assert [%EmbeddingModel{id: ^new_id, name: "hashing/2"}] = Repo.all(EmbeddingModel)
    end

    test "keeps the old model row while a page still uses it" do
      docs = for i <- 1..2, do: document_fixture(body: "page #{i}")
      switch_embedding_model(2)

      assert {:ok, %{more?: true}} = Documents.reembed_stale(limit: 1)
      assert Repo.aggregate(EmbeddingModel, :count) == 2
      assert length(docs) == 2
    end

    test "is a no-op on a current index" do
      document_fixture()
      assert {:ok, %{documents: 0, more?: false}} = Documents.reembed_stale()
    end
  end
end
