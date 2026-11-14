defmodule Knowseek.Documents.ModelWatchTest do
  use Knowseek.DataCase, async: false

  import ExUnit.CaptureLog

  alias Knowseek.Documents
  alias Knowseek.Documents.{Document, EmbeddingModel, ModelWatch, ReembedWorker}
  alias Knowseek.Embeddings

  defp start_watch(opts) do
    name = :"model_watch_#{System.unique_integer([:positive])}"
    start_supervised!({ModelWatch, Keyword.merge([name: name, check_ms: :manual], opts)})
  end

  defp checked(test_pid) do
    send(test_pid, :checked)
    :current
  end

  defp tick(pid) do
    send(pid, :tick)
    _ = :sys.get_state(pid)
  end

  defp info_logs do
    Logger.put_module_level(ModelWatch, :info)
    on_exit(fn -> Logger.delete_module_level(ModelWatch) end)
  end

  describe "the process" do
    test "a :tick runs the check" do
      test_pid = self()
      pid = start_watch(check: fn -> checked(test_pid) end)

      refute_received :checked
      tick(pid)
      assert_received :checked
    end

    test "a raising check does not stop the process, and is logged as a warning" do
      pid = start_watch(check: fn -> raise "database is busy" end)

      log = capture_log(fn -> tick(pid) end)

      assert log =~ "embedding model check failed: database is busy"
      assert Process.alive?(pid)
    end

    test "logs a change to :reembedding and back to :current once" do
      info_logs()
      document_fixture()
      {:ok, results} = Agent.start_link(fn -> [:current] end)
      pid = start_watch(check: fn -> Agent.get(results, &hd/1) end)

      assert capture_log(fn -> tick(pid) end) == ""

      switch_embedding_model(2)
      Agent.update(results, fn _ -> [:reembedding] end)

      first = capture_log(fn -> tick(pid) end)
      assert first =~ "embedding model hashing/2: 0 of 1 passages have this model's vectors"
      assert first =~ "re-embedding the rest in the background"
      assert capture_log(fn -> tick(pid) end) == ""

      Agent.update(results, fn _ -> [:current] end)
      assert capture_log(fn -> tick(pid) end) =~ "re-embedding finished"
      assert capture_log(fn -> tick(pid) end) == ""
    end

    test "logs a warning when the provider cannot say its model, once" do
      pid = start_watch(check: fn -> {:error, {:ollama, :model_not_found}} end)

      log = capture_log(fn -> tick(pid) end)
      assert log =~ "cannot ask the embedding provider for its model: {:ollama, :model_not_found}"
      assert capture_log(fn -> tick(pid) end) == ""
    end

    test "checks right after the start when it has a timer" do
      test_pid = self()
      start_watch(check_ms: 3_600_000, check: fn -> checked(test_pid) end)

      assert_receive :checked
    end
  end

  describe "Documents.check_model/0" do
    test "is :current on a fresh index" do
      assert Documents.check_model() == :current
      document_fixture()
      assert Documents.check_model() == :current
      refute_enqueued(worker: ReembedWorker)
    end

    test "is :reembedding and enqueues one job after a model change" do
      document_fixture()
      Application.put_env(:knowseek, Embeddings.Hashing, version: 2)

      on_exit(fn ->
        Application.delete_env(:knowseek, Embeddings.Hashing)
        Embeddings.refresh_model()
      end)

      assert Documents.check_model() == :reembedding
      assert Documents.check_model() == :reembedding

      assert [_one] = all_enqueued(worker: ReembedWorker)
    end

    # What the migration leaves: pages without a model, no model row, no vectors.
    test "is :reembedding for the state the migration leaves, and reembed_stale/1 fills it" do
      docs = for i <- 1..2, do: document_fixture(body: "page #{i}")
      Repo.update_all(Document, set: [embedding_model_id: nil])
      Repo.delete_all(EmbeddingModel)
      Repo.query!("DELETE FROM chunk_vectors")

      assert {:ok, nil} = Documents.current_model_id()
      assert Documents.reembedding?()
      assert Documents.reembed_progress() == %{done: 0, total: 2}
      assert Documents.check_model() == :reembedding
      assert_enqueued(worker: ReembedWorker)

      assert {:ok, %{documents: 2, more?: false}} = Documents.reembed_stale()

      {:ok, id} = Documents.current_model_id()
      assert is_integer(id)

      for document <- docs do
        assert Repo.reload!(document).embedding_model_id == id
        assert vector_model_ids(document) == [id]
      end

      assert Documents.check_model() == :current
    end

    test "is {:error, _} and enqueues nothing when the adapter cannot say its model" do
      config = Application.fetch_env!(:knowseek, Embeddings)

      on_exit(fn ->
        Application.put_env(:knowseek, Embeddings, config)
        Embeddings.refresh_model()
      end)

      document_fixture()
      Application.put_env(:knowseek, Embeddings, Keyword.put(config, :adapter, Embeddings.Ollama))
      Req.Test.stub(Embeddings.Ollama, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, {:ollama, %Req.TransportError{}}} = Documents.check_model()
      refute_enqueued(worker: ReembedWorker)
    end
  end
end
