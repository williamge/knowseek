defmodule Knowseek.Discovery.PlaygroundTest do
  # Changes global config (the playground and the planner), and the stubs are
  # called from a task.
  use Knowseek.DataCase, async: false

  # A planner that fails logs a warning.
  @moduletag :capture_log

  alias Knowseek.Discovery.{ModelPlanner, Playground}
  alias Knowseek.Discovery.Planner.Ollama
  alias Knowseek.Discovery.Sources.Wikipedia

  setup do
    config = Application.get_env(:knowseek, Playground)

    on_exit(fn ->
      Application.delete_env(:knowseek, ModelPlanner)

      if config,
        do: Application.put_env(:knowseek, Playground, config),
        else: Application.delete_env(:knowseek, Playground)
    end)

    Application.put_env(:knowseek, Playground, planner: ModelPlanner, model_timeout: 200)
    ModelPlanner.notify(self())
    :ok
  end

  defp tag(name, size, extra \\ %{}) do
    Map.merge(
      %{
        "name" => name,
        "size" => size,
        "details" => %{"family" => "qwen2", "parameter_size" => "3.1B"},
        "capabilities" => ["completion", "tools"]
      },
      extra
    )
  end

  # Answers /api/tags and /api/ps like Ollama.
  defp stub_ollama(tags, loaded \\ []) do
    Req.Test.stub(Ollama, fn conn ->
      case conn.request_path do
        "/api/tags" -> Req.Test.json(conn, %{"models" => tags})
        "/api/ps" -> Req.Test.json(conn, %{"models" => Enum.map(loaded, &%{"name" => &1})})
        "/api/chat" -> unload_reply(conn)
      end
    end)
  end

  # What `/api/chat` answers to an unload (`keep_alive: 0`); the request is
  # sent to the test process. `Process.get(:unload_status)` can make it fail.
  defp unload_reply(conn) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    send(self(), {:ollama_chat, Jason.decode!(raw)})
    Req.Test.json(conn, %{"done" => true, "done_reason" => "unload"})
  end

  # Wikipedia's search: a map of query to the titles it finds.
  defp stub_wikipedia(titles_by_query) do
    Req.Test.stub(Wikipedia, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(self(), {:wikipedia, conn.query_params})
      %{"list" => "search", "srsearch" => query} = conn.query_params
      search_reply(conn, Map.get(titles_by_query, query, []))
    end)
  end

  defp search_reply(conn, :error), do: Plug.Conn.send_resp(conn, 500, "")

  defp search_reply(conn, titles) do
    search =
      for {title, id} <- Enum.with_index(titles, 1), do: %{"pageid" => id, "title" => title}

    Req.Test.json(conn, %{"query" => %{"search" => search}})
  end

  describe "models/0" do
    test "lists the chat models smallest first, hides embedding models, and marks the default" do
      stub_ollama([
        tag("qwen2.5-coder:7b", 4_683_087_561),
        tag("bge-m3:latest", 1_157_672_605, %{
          "details" => %{"family" => "bert"},
          "capabilities" => ["embedding"]
        }),
        tag("qwen3:1.7b", 1_929_912_432)
      ])

      assert {:ok, %{models: [small, big], default: "qwen3:1.7b", loaded: [], warning: nil}} =
               Playground.models()

      assert %{name: "qwen3:1.7b", size_bytes: 1_929_912_432, parameter_size: "3.1B"} = small
      assert small.default
      refute small.loaded
      assert %{name: "qwen2.5-coder:7b", default: false} = big
    end

    test "hides an embedding model by its family when Ollama lists no capabilities" do
      stub_ollama([
        Map.delete(tag("nomic-embed-text:latest", 274_302_450), "capabilities")
        |> put_in(["details", "family"], "nomic-bert"),
        Map.delete(tag("llama3.2:3b", 2_019_377_376), "capabilities")
      ])

      assert {:ok, %{models: [%{name: "llama3.2:3b"}]}} = Playground.models()
    end

    test "says which models are loaded, and warns when more than one chat model is" do
      stub_ollama(
        [
          tag("qwen3:1.7b", 1),
          tag("qwen2.5-coder:7b", 2),
          tag("bge-m3:latest", 3, %{"capabilities" => ["embedding"]})
        ],
        ["bge-m3:latest", "qwen3:1.7b", "qwen2.5-coder:7b"]
      )

      assert {:ok, %{loaded: loaded, warning: warning, models: models}} = Playground.models()
      assert loaded == ["qwen3:1.7b", "qwen2.5-coder:7b"]
      assert warning =~ "2 chat models are loaded"
      assert warning =~ "do not stop bge-m3"
      assert Enum.all?(models, & &1.loaded)
    end

    test "no warning for one loaded chat model next to the embedding model" do
      stub_ollama([tag("qwen3:1.7b", 1)], ["bge-m3:latest", "qwen3:1.7b"])
      assert {:ok, %{loaded: ["qwen3:1.7b"], warning: nil}} = Playground.models()
    end

    test "an Ollama that does not answer is an error with a message" do
      Req.Test.stub(Ollama, &Req.Test.transport_error(&1, :econnrefused))
      assert {:error, message} = Playground.models()
      assert message =~ "Ollama did not answer"

      Req.Test.stub(Ollama, &Plug.Conn.send_resp(&1, 500, ""))
      assert {:error, "Ollama answered HTTP 500 for /api/tags"} = Playground.models()
    end
  end

  describe "preview/3" do
    setup do
      stub_ollama([], ["good"])

      stub_wikipedia(%{
        "tide pools" => ["Tide pool", "Tide", "Pool"],
        "rock pool" => ["Tide pool", "Rock pool", "Intertidal zone", "Rockpool shrimp"],
        "intertidal" => ["Intertidal zone", "Tide"],
        "tide" => ["Tide", "Tidal power"]
      })
    end

    test "plans with each model in the order given, with the model as a per-call option" do
      assert %{query: "tide pools", results: [good, other]} =
               Playground.preview("tide pools", ["good", "other"])

      assert good.model == "good"
      assert other.model == "other"
      assert good.queries == ["tide pools", "rock pool", "intertidal"]
      assert other.queries == ["tide pools", "tide"]

      assert_received {:model_planner, "tide pools", first}
      assert_received {:model_planner, "tide pools", second}
      assert first[:model] == "good"
      assert second[:model] == "other"
      assert first[:keep_alive] == "1m"
      refute_received {:model_planner, _query, _opts}
    end

    test "unloads each chat model after its call, and never an embedding model" do
      stub_ollama(
        [
          tag("good", 1),
          tag("other", 2),
          tag("bge-m3:latest", 3, %{"capabilities" => ["embedding"]})
        ],
        []
      )

      assert %{results: [good, other, embed, unknown]} =
               Playground.preview("tide pools", ["good", "other", "bge-m3:latest", "nope"],
                 source: false
               )

      assert [good.unloaded, other.unloaded, embed.unloaded, unknown.unloaded] ==
               [true, true, false, false]

      assert_received {:ollama_chat, %{"model" => "good", "keep_alive" => 0} = first}
      assert_received {:ollama_chat, %{"model" => "other", "keep_alive" => 0}}
      refute Map.has_key?(first, "messages")
      refute_received {:ollama_chat, _another}
    end

    test "a model is unloaded before the next one starts" do
      stub_ollama([tag("good", 1), tag("other", 2)], [])
      Playground.preview("tide pools", ["good", "other"], source: false)

      messages = drain()

      order =
        for message <- messages,
            reduce: [] do
          acc ->
            case message do
              {:model_planner, _query, opts} -> acc ++ [{:plan, opts[:model]}]
              {:ollama_chat, %{"model" => model}} -> acc ++ [{:unload, model}]
              _other -> acc
            end
        end

      assert order == [{:plan, "good"}, {:unload, "good"}, {:plan, "other"}, {:unload, "other"}]
    end

    test "an unload that fails is reported and does not fail the result" do
      Req.Test.stub(Ollama, fn conn ->
        case conn.request_path do
          "/api/tags" -> Req.Test.json(conn, %{"models" => [tag("good", 1)]})
          "/api/ps" -> Req.Test.json(conn, %{"models" => []})
          "/api/chat" -> Plug.Conn.send_resp(conn, 500, "")
        end
      end)

      assert %{results: [%{status: "ok", unloaded: false}]} =
               Playground.preview("tide pools", ["good"], source: false)
    end

    test "the model option reaches Ollama, and the global setting stays" do
      Application.put_env(:knowseek, Playground, model_timeout: 200)
      config = Application.fetch_env!(:knowseek, Ollama)
      test_pid = self()

      Req.Test.stub(Ollama, fn conn ->
        case conn.request_path do
          "/api/ps" ->
            Req.Test.json(conn, %{"models" => []})

          "/api/tags" ->
            Req.Test.json(conn, %{"models" => []})

          "/api/chat" ->
            {:ok, raw, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:chat, Jason.decode!(raw)})
            content = Jason.encode!(%{"queries" => ["rock pool"]})
            Req.Test.json(conn, %{"message" => %{"content" => content}})
        end
      end)

      assert %{results: [%{model: "tiny:1b", status: "ok", warm: false, queries: queries}]} =
               Playground.preview("tide pools", ["tiny:1b"], source: false)

      assert queries == ["tide pools", "rock pool"]
      assert_received {:chat, %{"model" => "tiny:1b", "keep_alive" => "1m"}}
      assert Application.fetch_env!(:knowseek, Ollama) == config
    end

    test "returns the plan, the titles of every search, and the titles only planning found" do
      assert %{
               literal: %{titles: ["Tide pool", "Tide", "Pool"], error: nil},
               results: [
                 %{source: source, status: "ok", detail: nil, warm: true, plan_ms: plan_ms}
               ]
             } = Playground.preview("tide pools", ["good"])

      assert is_integer(plan_ms) and plan_ms >= 0

      assert source.literal.titles == ["Tide pool", "Tide", "Pool"]

      # Top 3 of each search; titles of the literal search are not "extra".
      assert source.searches == [
               %{
                 query: "rock pool",
                 titles: ["Tide pool", "Rock pool", "Intertidal zone"],
                 error: nil
               },
               %{query: "intertidal", titles: ["Intertidal zone", "Tide"], error: nil}
             ]

      assert source.only_planned == ["Rock pool", "Intertidal zone"]
      assert is_integer(source.wiki_ms)
    end

    test "the query as typed is searched once for all the models" do
      Playground.preview("tide pools", ["good", "other"])

      searched = for {:wikipedia, %{"srsearch" => query}} <- drain(), do: query
      assert Enum.count(searched, &(&1 == "tide pools")) == 1
    end

    test "source: false searches nothing" do
      assert %{literal: nil, results: [%{source: nil, queries: [_, _, _]}]} =
               Playground.preview("tide pools", ["good"], source: false)

      refute_received {:wikipedia, _params}
    end

    test "a planner that fails falls back to the query as typed, and says why" do
      assert %{results: [bad]} = Playground.preview("tide pools", ["bad"])

      assert bad.status == "fallback"
      assert bad.detail == ":model_missing"
      assert bad.queries == ["tide pools"]
      assert bad.source.searches == []
      assert bad.source.only_planned == []
    end

    test "a model that crashes, one that times out, and one that works: the others still answer" do
      assert %{results: [crash, slow, good]} =
               Playground.preview("tide pools", ["crash", "slow", "good"], source: false)

      assert crash.status == "fallback"
      assert crash.detail =~ "model crashed"

      assert %{status: "timeout", detail: "no answer within 0.2 s", queries: ["tide pools"]} =
               slow

      assert slow.plan_ms >= 200

      assert good.status == "ok"
    end

    test "a failed Wikipedia search is reported where it happened" do
      stub_wikipedia(%{
        "tide pools" => ["Tide pool"],
        "rock pool" => :error,
        "intertidal" => ["Tide"]
      })

      assert %{results: [%{source: source}]} = Playground.preview("tide pools", ["good"])

      assert [%{query: "rock pool", titles: [], error: error}, %{titles: ["Tide"]}] =
               source.searches

      assert error =~ "http_status"
      assert source.only_planned == ["Tide"]

      stub_wikipedia(%{"tide pools" => :error})

      assert %{literal: %{titles: [], error: error}} = Playground.preview("tide pools", ["good"])
      assert error =~ "http_status"
    end

    test "warns when several models run, not for one" do
      assert %{warning: warning} = Playground.preview("q", ["good", "other"], source: false)
      assert warning =~ "2 models run one after another"
      assert %{warning: nil} = Playground.preview("q", ["good"], source: false)
    end

    test "never writes: no documents, no jobs" do
      Playground.preview("tide pools", ["good"])
      assert Knowseek.Documents.list_documents() == []
    end

    defp drain do
      receive do
        message -> [message | drain()]
      after
        0 -> []
      end
    end
  end
end
