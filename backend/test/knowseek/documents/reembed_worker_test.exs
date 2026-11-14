defmodule Knowseek.Documents.ReembedWorkerTest do
  use Knowseek.DataCase, async: false

  alias Knowseek.Documents
  alias Knowseek.Documents.ReembedWorker
  alias Knowseek.Embeddings

  describe "perform/1" do
    test "re-embeds, and enqueues one successor while pages are left" do
      config = Application.fetch_env!(:knowseek, Documents.Reembed)

      Application.put_env(
        :knowseek,
        Documents.Reembed,
        Keyword.put(config, :documents_per_job, 1)
      )

      on_exit(fn -> Application.put_env(:knowseek, Documents.Reembed, config) end)

      docs = for i <- 1..2, do: document_fixture(body: "page #{i}")
      switch_embedding_model(2)

      assert :ok = perform_job(ReembedWorker, %{})

      {:ok, new_id} = Documents.current_model_id()
      assert [first, second] = Enum.map(docs, &Repo.reload!/1)
      assert first.embedding_model_id == new_id
      assert second.embedding_model_id != new_id
      assert [_one] = all_enqueued(worker: ReembedWorker)

      assert :ok = perform_job(ReembedWorker, %{})
      assert Repo.reload!(second).embedding_model_id == new_id
      # The first job's successor is still the only one: this run enqueued none.
      assert [_one] = all_enqueued(worker: ReembedWorker)
      refute Documents.reembedding?()
    end

    test "enqueues nothing when the index is current" do
      document_fixture()
      assert :ok = perform_job(ReembedWorker, %{})
      refute_enqueued(worker: ReembedWorker)
    end

    test "returns the error of a failed embedding" do
      config = Application.fetch_env!(:knowseek, Embeddings)
      on_exit(fn -> Application.put_env(:knowseek, Embeddings, config) end)

      document_fixture()
      switch_embedding_model(2)

      Application.put_env(
        :knowseek,
        Embeddings,
        Keyword.put(config, :adapter, Embeddings.HookAdapter)
      )

      Application.put_env(:knowseek, Embeddings.HookAdapter, hook: fn _ -> {:error, :boom} end)
      on_exit(fn -> Application.delete_env(:knowseek, Embeddings.HookAdapter) end)

      assert {:error, :boom} = perform_job(ReembedWorker, %{})
      refute_enqueued(worker: ReembedWorker)
    end
  end

  describe "enqueue/0" do
    test "twice leaves one job" do
      assert :ok = ReembedWorker.enqueue()
      assert :ok = ReembedWorker.enqueue()

      assert [_one] = all_enqueued(worker: ReembedWorker)
    end
  end
end
