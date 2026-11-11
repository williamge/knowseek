defmodule Knowseek.DiscoveryTest do
  # SeekWorker tests change the global source list.
  use Knowseek.DataCase, async: false

  alias Knowseek.Activity.NetworkUsage
  alias Knowseek.Discovery

  alias Knowseek.Discovery.{
    BadCandidateSource,
    CountingFailingSource,
    CountingSource,
    FailingSource,
    FakeSource,
    SeekWorker
  }

  alias Knowseek.Documents

  describe "request/1" do
    test "enqueues a seek job with the normalized query" do
      {:ok, _job} = Discovery.request("  Rust   ASYNC ")
      assert_enqueued(worker: SeekWorker, args: %{"query" => "rust async"})
    end

    test "deduplicates the same query" do
      {:ok, first} = Discovery.request("rust async")
      {:ok, second} = Discovery.request("Rust async")

      assert second.conflict?
      assert second.id == first.id
    end
  end

  describe "SeekWorker" do
    setup do
      config = Application.fetch_env!(:knowseek, Discovery)
      on_exit(fn -> Application.put_env(:knowseek, Discovery, config) end)

      %{put_sources: &Application.put_env(:knowseek, Discovery, sources: &1)}
    end

    test "nothing found is :ok" do
      assert :ok = perform_job(SeekWorker, %{"query" => "tide pools"})
    end

    test "a failing source alone is :ok", %{put_sources: put_sources} do
      put_sources.([FailingSource])
      assert :ok = perform_job(SeekWorker, %{"query" => "tide pools"})
    end

    test "some ingested and some failed is :ok", %{put_sources: put_sources} do
      put_sources.([FakeSource, BadCandidateSource])
      assert :ok = perform_job(SeekWorker, %{"query" => "tide pools"})
    end

    test "every candidate failing to ingest returns an error so Oban retries", %{
      put_sources: put_sources
    } do
      put_sources.([BadCandidateSource])

      assert {:error, {:all_ingests_failed, 1}} =
               perform_job(SeekWorker, %{"query" => "tide pools"})
    end
  end

  describe "run/2" do
    test "ingests candidates from every source and tags them with the source name" do
      assert {:ok, %{ingested: 1, failed: 0}} =
               Discovery.run("tide pools", sources: [FakeSource, FailingSource])

      assert [%{source: "fake", title: "About tide pools"}] = Documents.list_documents()
    end

    test "the ingested documents come from a search, with the query" do
      assert {:ok, %{ingested: 1}} = Discovery.run("tide pools", sources: [FakeSource])

      assert [%{origin: "search", origin_query: "tide pools"}] = Documents.list_documents()
    end

    test "a query over 500 characters is cut in origin_query" do
      query = String.duplicate("a", 600)

      assert {:ok, %{ingested: 1}} = Discovery.run(query, sources: [FakeSource])

      assert [%{origin_query: origin_query}] = Documents.list_documents()
      assert origin_query == String.duplicate("a", 500)
    end

    test "records the bytes a source reports, once, under its name" do
      assert {:ok, %{ingested: 1}} = Discovery.run("tide pools", sources: [CountingSource])

      today = Date.utc_today()

      assert [%NetworkUsage{day: ^today, source: "counting", bytes: 2_000}] =
               Repo.all(NetworkUsage)
    end

    test "records the bytes of a source that failed, and the run still succeeds" do
      assert {:ok, %{ingested: 0, failed: 0}} =
               Discovery.run("tide pools", sources: [CountingFailingSource])

      assert [%NetworkUsage{source: "counting_failing", bytes: 500}] = Repo.all(NetworkUsage)
    end

    test "a source that reports nothing leaves no row" do
      assert {:ok, %{ingested: 1}} = Discovery.run("tide pools", sources: [FakeSource])

      assert Repo.all(NetworkUsage) == []
    end
  end
end
