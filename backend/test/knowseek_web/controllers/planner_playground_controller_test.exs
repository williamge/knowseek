defmodule KnowseekWeb.PlannerPlaygroundControllerTest do
  # The playground routes exist only in dev (`:dev_routes`), so the actions are
  # called directly, with the params that Phoenix would parse from a JSON body.
  use KnowseekWeb.ConnCase, async: false

  @moduletag :capture_log

  alias Knowseek.Discovery.{ModelPlanner, Playground}
  alias Knowseek.Discovery.Planner.Ollama
  alias Knowseek.Discovery.Sources.Wikipedia
  alias KnowseekWeb.PlannerPlaygroundController, as: Controller

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

    Req.Test.stub(Ollama, fn conn ->
      case conn.request_path do
        "/api/tags" ->
          Req.Test.json(conn, %{
            "models" => [
              %{
                "name" => "qwen2.5:3b",
                "size" => 1_929_912_432,
                "capabilities" => ["completion"]
              },
              %{"name" => "bge-m3:latest", "size" => 1, "capabilities" => ["embedding"]}
            ]
          })

        "/api/ps" ->
          Req.Test.json(conn, %{"models" => []})

        "/api/chat" ->
          Req.Test.json(conn, %{"done" => true})
      end
    end)

    Req.Test.stub(Wikipedia, fn conn ->
      Req.Test.json(conn, %{"query" => %{"search" => [%{"pageid" => 1, "title" => "Tide pool"}]}})
    end)

    :ok
  end

  describe "the routes" do
    test "do not exist when :dev_routes is off (test and release)" do
      refute Application.get_env(:knowseek, :dev_routes)

      paths = KnowseekWeb.Router |> Phoenix.Router.routes() |> Enum.map(& &1.path)
      refute Enum.any?(paths, &String.starts_with?(&1, "/api/planner"))
    end

    test "dev.exs turns them on" do
      dev = File.read!(Path.expand("../../../config/dev.exs", __DIR__))
      assert dev =~ "config :knowseek, dev_routes: true"
    end

    test "a request to the playground is a 404 here", %{conn: conn} do
      assert post(conn, "/api/planner/preview", %{query: "q"}) |> response(404)
      assert get(build_conn(), "/api/planner/models") |> response(404)
    end
  end

  describe "models" do
    test "lists the chat models and the default", %{conn: conn} do
      conn = Controller.models(conn, %{})

      assert %{"data" => %{"models" => [model], "default" => "qwen2.5:3b", "warning" => nil}} =
               json_response(conn, 200)

      assert %{"name" => "qwen2.5:3b", "size_bytes" => 1_929_912_432, "default" => true} = model
    end

    test "is a 503 with a message when Ollama does not answer", %{conn: conn} do
      Req.Test.stub(Ollama, &Req.Test.transport_error(&1, :econnrefused))

      conn = Controller.models(conn, %{})
      assert %{"errors" => %{"detail" => "Ollama did not answer" <> _}} = json_response(conn, 503)
    end
  end

  describe "preview" do
    test "runs the models in the order given and returns each result", %{conn: conn} do
      conn =
        Controller.preview(conn, %{
          "query" => "  tide pools ",
          "models" => ["good", "other"],
          "source" => true
        })

      assert %{
               "data" => %{
                 "query" => "tide pools",
                 "literal" => literal,
                 "results" => [good, other]
               }
             } =
               json_response(conn, 200)

      assert literal["titles"] == ["Tide pool"]

      assert %{
               "model" => "good",
               "status" => "ok",
               "queries" => ["tide pools", "rock pool", "intertidal"]
             } = good

      assert %{"model" => "other", "queries" => ["tide pools", "tide"]} = other
      assert %{"source" => %{"only_planned" => [], "searches" => [_, _]}} = good
    end

    test "defaults to the configured model and to searching Wikipedia", %{conn: conn} do
      conn = Controller.preview(conn, %{"query" => "tide pools"})

      assert %{"data" => %{"results" => [%{"model" => "qwen2.5:3b", "source" => %{}}]}} =
               json_response(conn, 200)
    end

    test "source: false returns no source part", %{conn: conn} do
      conn = Controller.preview(conn, %{"query" => "q", "models" => ["good"], "source" => false})

      assert %{"data" => %{"literal" => nil, "results" => [%{"source" => nil}]}} =
               json_response(conn, 200)
    end

    test "one model that fails does not fail the request", %{conn: conn} do
      conn =
        Controller.preview(conn, %{
          "query" => "q",
          "models" => ["bad", "slow", "good"],
          "source" => false
        })

      assert %{
               "data" => %{
                 "results" => [
                   %{"status" => "fallback"},
                   %{"status" => "timeout"},
                   %{"status" => "ok"}
                 ]
               }
             } =
               json_response(conn, 200)
    end

    test "accepts at most 4 models, and runs none of them otherwise", %{conn: conn} do
      conn = Controller.preview(conn, %{"query" => "q", "models" => ~w(a b c d e)})
      assert %{"errors" => %{"detail" => "at most 4 models at a time"}} = json_response(conn, 400)
      refute_received {:model_planner, _query, _opts}

      conn =
        Controller.preview(build_conn(), %{
          "query" => "q",
          "models" => ~w(a b c d),
          "source" => false
        })

      assert %{"data" => %{"results" => results}} = json_response(conn, 200)
      assert length(results) == 4
    end

    test "the same model twice runs once", %{conn: conn} do
      conn =
        Controller.preview(conn, %{
          "query" => "q",
          "models" => ["good", " good "],
          "source" => false
        })

      assert %{"data" => %{"results" => [_only_one]}} = json_response(conn, 200)
    end

    test "rejects a bad request with a message", %{conn: conn} do
      bad = [
        {%{}, "query is required"},
        {%{"query" => "   "}, "query is required"},
        {%{"query" => 5}, "query is required"},
        {%{"query" => String.duplicate("a", 501)}, "query is at most 500 characters"},
        {%{"query" => "q", "models" => []}, "models must be a list of model names"},
        {%{"query" => "q", "models" => "good"}, "models must be a list of model names"},
        {%{"query" => "q", "models" => ["good", 7]}, "models must be a list of model names"},
        {%{"query" => "q", "models" => [""]}, "models must be a list of model names"},
        {%{"query" => "q", "source" => "yes"}, "source must be true or false"}
      ]

      for {params, message} <- bad do
        conn = Controller.preview(build_conn(), params)
        assert %{"errors" => %{"detail" => ^message}} = json_response(conn, 400)
      end

      refute_received {:model_planner, _query, _opts}
      _ = conn
    end
  end
end
