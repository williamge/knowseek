defmodule Knowseek.DiscoveryTest do
  # SeekWorker tests change the global source list.
  use Knowseek.DataCase, async: false

  import ExUnit.CaptureLog

  alias Knowseek.Discovery

  alias Knowseek.Discovery.{
    BadCandidateSource,
    FailingSource,
    FakePlanner,
    FakeSource,
    Planner,
    ScriptedSource,
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

  describe "SeekWorker with a planner" do
    setup do
      discovery = Application.fetch_env!(:knowseek, Discovery)
      planner = Application.fetch_env!(:knowseek, Planner)

      on_exit(fn ->
        Application.put_env(:knowseek, Discovery, discovery)
        Application.put_env(:knowseek, Planner, planner)
      end)

      Application.put_env(:knowseek, Planner, Keyword.put(planner, :adapter, FakePlanner))
      FakePlanner.put(["pools", "tides"])
      :ok
    end

    defp put_sources(sources), do: Application.put_env(:knowseek, Discovery, sources: sources)

    test "the plan is searched, and the job is :ok" do
      put_sources([FakeSource])

      assert :ok = perform_job(SeekWorker, %{"query" => "tide pools"})

      assert Documents.list_documents() |> Enum.map(& &1.title) |> Enum.sort() ==
               ["About pools", "About tide pools", "About tides"]
    end

    test "a failing planner does not fail the job: the original query is searched" do
      put_sources([FakeSource])
      FakePlanner.put({:error, :model_missing})

      assert :ok = perform_job(SeekWorker, %{"query" => "tide pools"})
      assert [%{title: "About tide pools"}] = Documents.list_documents()
    end

    test "every candidate of every planned query failing to ingest returns an error" do
      put_sources([BadCandidateSource])

      assert {:error, {:all_ingests_failed, 3}} =
               perform_job(SeekWorker, %{"query" => "tide pools"})
    end

    test "a planner fallback and an original query whose candidates all fail still retries" do
      put_sources([BadCandidateSource])
      FakePlanner.put({:error, :timeout})

      assert {:error, {:all_ingests_failed, 1}} =
               perform_job(SeekWorker, %{"query" => "tide pools"})
    end

    test "some candidates ingested and some failed is :ok" do
      put_sources([FakeSource, BadCandidateSource])

      assert :ok = perform_job(SeekWorker, %{"query" => "tide pools"})
      assert length(Documents.list_documents()) == 3
    end

    test "planned queries that find nothing, or fail, are :ok, never a retry" do
      put_sources([FailingSource])
      assert :ok = perform_job(SeekWorker, %{"query" => "tide pools"})

      put_sources([])
      assert :ok = perform_job(SeekWorker, %{"query" => "tide pools"})
    end

    test "the plan is not in the job arguments, so uniqueness stays per user query" do
      {:ok, first} = Discovery.request("Tide  pools")
      {:ok, second} = Discovery.request("tide pools")

      assert second.conflict?
      assert first.args == %{"query" => "tide pools"}
    end
  end

  describe "run/2" do
    test "ingests candidates from every source and tags them with the source name" do
      assert {:ok, %{ingested: 1, failed: 0}} =
               Discovery.run("tide pools", sources: [FakeSource, FailingSource])

      assert [%{source: "fake", title: "About tide pools"}] = Documents.list_documents()
    end

    test "with the pass-through planner, the summary says nothing was planned" do
      assert {:ok, %{ingested: 1, failed: 0, plan: ["Tide  Pools"], planner: :passthrough}} =
               Discovery.run("Tide  Pools", sources: [FakeSource])
    end
  end

  describe "run/2 with a planner" do
    defp run(query, plan, results, opts \\ []) do
      FakePlanner.put(plan)
      ScriptedSource.put(results)

      Discovery.run(query, Keyword.merge([sources: [ScriptedSource], planner: FakePlanner], opts))
    end

    defp asked do
      for {:scripted_source_asked, query} <- drain(), do: query
    end

    defp drain do
      receive do
        message -> [message | drain()]
      after
        0 -> []
      end
    end

    defp urls, do: Documents.list_documents() |> Enum.map(& &1.url) |> Enum.sort()

    test "searches the original query first, then every planned query, with every source" do
      assert {:ok, %{ingested: 0, plan: ["tide pools", "rock pool", "intertidal"], planner: :ok}} =
               run("tide pools", ["rock pool", "intertidal"], %{})

      assert asked() == ["tide pools", "rock pool", "intertidal"]
    end

    test "merges the candidates of every query and ingests each URL once" do
      a = ScriptedSource.candidate("https://x.example/a", "A")
      b = ScriptedSource.candidate("https://x.example/b", "B")
      c = ScriptedSource.candidate("https://x.example/c", "C")
      # The same pages again, under other spellings of their URLs.
      a_again = ScriptedSource.candidate("HTTPS://X.example/a?utm_source=x#top", "A again")
      b_again = ScriptedSource.candidate("https://x.example/b", "B again")

      results = %{
        "q" => {:ok, [a, b]},
        "one" => {:ok, [a_again, c]},
        "two" => {:ok, [b_again]}
      }

      assert {:ok, %{ingested: 3, failed: 0}} = run("q", ["one", "two"], results)
      assert urls() == ["https://x.example/a", "https://x.example/b", "https://x.example/c"]

      # The first candidate of a URL in the merge order (rounds: the first of
      # every query, then the second of every query) is the one ingested.
      assert Documents.list_documents() |> Enum.map(& &1.title) |> Enum.sort() ==
               ["A", "B again", "C"]
    end

    test "the cap keeps the original query's candidates first and shares the rest in rounds" do
      candidates = fn prefix ->
        {:ok, for(n <- 1..3, do: ScriptedSource.candidate("https://x.example/#{prefix}#{n}"))}
      end

      results = %{"q" => candidates.("q"), "one" => candidates.("o"), "two" => candidates.("t")}

      assert {:ok, %{ingested: 4, failed: 0}} =
               run("q", ["one", "two"], results, max_candidates: 4)

      assert urls() == for(u <- ~w(o1 q1 q2 t1), do: "https://x.example/#{u}")
    end

    test "the cap comes from config" do
      config = Application.fetch_env!(:knowseek, Discovery)
      on_exit(fn -> Application.put_env(:knowseek, Discovery, config) end)
      Application.put_env(:knowseek, Discovery, Keyword.put(config, :max_candidates, 2))

      results = %{
        "q" => {:ok, for(n <- 1..5, do: ScriptedSource.candidate("https://x.example/#{n}"))}
      }

      assert {:ok, %{ingested: 2}} = run("q", [], results)
    end

    test "the default cap is 12" do
      assert Discovery.max_candidates() == 12
    end

    test "one planned query failing costs only its own candidates" do
      results = %{
        "q" => {:ok, [ScriptedSource.candidate("https://x.example/q")]},
        "bad" => {:error, :http_500},
        "good" => {:ok, [ScriptedSource.candidate("https://x.example/good")]}
      }

      log = capture_log(fn -> send(self(), {:result, run("q", ["bad", "good"], results)}) end)

      assert_received {:result, {:ok, %{ingested: 2, failed: 0, planner: :ok}}}
      assert log =~ ~s(failed for "bad")
      assert urls() == ["https://x.example/good", "https://x.example/q"]
    end

    test "the original query failing does not stop the planned queries" do
      results = %{
        "q" => {:error, :unavailable},
        "good" => {:ok, [ScriptedSource.candidate("https://x.example/good")]}
      }

      capture_log(fn -> send(self(), {:result, run("q", ["good"], results)}) end)
      assert_received {:result, {:ok, %{ingested: 1}}}
    end

    test "a planner that fails falls back to the original query, and the summary says why" do
      results = %{"q" => {:ok, [ScriptedSource.candidate("https://x.example/q")]}}

      log =
        capture_log(fn ->
          send(self(), {:result, run("q", {:error, {:ollama, 404, "model not found"}}, results)})
        end)

      assert_received {:result,
                       {:ok,
                        %{
                          ingested: 1,
                          plan: ["q"],
                          planner: {:fallback, {:ollama, 404, "model not found"}}
                        }}}

      assert log =~ "[warning]"
      assert log =~ "model not found"
      assert asked() == ["q"]
    end

    test "counts ingest failures across all planned queries" do
      bad = %{url: "https://x.example/nobody"}
      results = %{"q" => {:ok, [bad]}, "one" => {:ok, [%{bad | url: "https://x.example/n2"}]}}

      capture_log(fn -> send(self(), {:result, run("q", ["one"], results)}) end)
      assert_received {:result, {:ok, %{ingested: 0, failed: 2}}}
    end

    test "a candidate without a URL is kept, not merged" do
      no_url = %{body: "A text without any address, long enough to be stored as a document."}
      results = %{"q" => {:ok, [no_url]}, "one" => {:ok, [no_url]}}

      capture_log(fn -> send(self(), {:result, run("q", ["one"], results)}) end)
      assert_received {:result, {:ok, summary}}
      assert summary.ingested + summary.failed == 2
    end

    test "logs the plan at info level" do
      Logger.put_module_level(Discovery, :info)
      on_exit(fn -> Logger.delete_module_level(Discovery) end)

      log = capture_log([level: :info], fn -> run("tide pools", ["rock pool"], %{}) end)

      assert log =~ "[info]"
      assert log =~ ~s(discovery plan for "tide pools": ["tide pools", "rock pool"])
    end
  end
end
