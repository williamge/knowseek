defmodule Knowseek.Fixtures do
  @moduledoc "Test data helpers."

  def document_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, document} =
      attrs
      |> Enum.into(%{
        url: "https://example.com/doc-#{n}",
        title: "Document #{n}",
        body: "Some body text for document #{n}.",
        source: "test"
      })
      |> Knowseek.Documents.ingest()

    document
  end

  @doc "The stored embedding of `chunk` (a list of floats), read from `chunk_vectors`."
  def chunk_embedding(%Knowseek.Documents.Chunk{seq: seq}),
    do: Knowseek.Repo.get!(Knowseek.Documents.ChunkVector, seq).embedding

  @wikidata_fixtures Path.expand("fixtures/wikidata", __DIR__)

  @doc """
  A recorded Wikidata API answer, decoded. `name` is a file in
  `test/support/fixtures/wikidata` without `.json`: `search_<query>` (a
  `wbsearchentities` answer for `knicks`, `nvidia`, `nvda`, `tokyo`, `texas`,
  `japan`, `apple`, `new york`, `washington`, `london`, `georgia` or `cambridge`; the
  file names use `_` for a space) or `entities_<query>` (the `wbgetentities` answer for the
  ids of that search). Recorded from wikidata.org, trimmed to the fields the
  resolver reads. Sitelinks are trimmed too: the `enwiki` entry is real, the
  others are empty placeholders (`x12`) that keep the count the resolver reads.
  The `texas`, `japan` and `apple` searches keep their first 8 hits.
  """
  def wikidata_fixture(name) do
    @wikidata_fixtures |> Path.join("#{name}.json") |> File.read!() |> Jason.decode!()
  end

  @doc """
  One recorded Wikidata item (the `wbgetentities` shape), for example
  `"Q182477"` (Nvidia). Tests change it to build a variant.
  """
  def wikidata_item(id) do
    ~w(knicks nvidia nvda tokyo texas japan apple new_york washington london georgia cambridge)
    |> Enum.map(&wikidata_fixture("entities_#{&1}"))
    |> Enum.find_value(&get_in(&1, ["entities", id]))
  end

  @doc """
  Stubs `Knowseek.Entities.Wikidata` HTTP calls (`Req.Test`) with the recorded
  answers. Searches for the queries of `wikidata_fixture/1` find their
  fixture; any other search (`weather in tokyo`, `zzzz`) finds nothing, as
  Wikidata does. `wbgetentities` answers for the requested ids.

  Each request sends `{:wikidata_request, action, params, user_agent}` to the
  calling process. The stub runs in the fetch task, so the test must use
  shared mode: `setup :set_req_test_from_context` in a non-async test.
  """
  def stub_wikidata do
    test_pid = self()

    items =
      ~w(knicks nvidia nvda tokyo texas japan apple new_york washington london georgia cambridge)
      |> Enum.map(&wikidata_fixture("entities_#{&1}")["entities"])
      |> Enum.reduce(%{}, &Map.merge/2)

    Req.Test.stub(Knowseek.Entities.Wikidata, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      params = conn.query_params
      user_agent = Plug.Conn.get_req_header(conn, "user-agent")
      send(test_pid, {:wikidata_request, params["action"], params, user_agent})

      Req.Test.json(conn, wikidata_answer(params, items))
    end)
  end

  defp wikidata_answer(%{"action" => "wbsearchentities", "search" => search}, _items) do
    fixture = "search_#{search |> String.downcase() |> String.replace(" ", "_")}"

    if File.exists?(Path.join(@wikidata_fixtures, "#{fixture}.json")) do
      wikidata_fixture(fixture)
    else
      %{"searchinfo" => %{"search" => search}, "search" => [], "success" => 1}
    end
  end

  defp wikidata_answer(%{"action" => "wbgetentities", "ids" => ids}, items) do
    entities =
      ids
      |> String.split("|")
      |> Map.new(fn id -> {id, Map.get(items, id, %{"id" => id, "missing" => ""})} end)

    %{"entities" => entities, "success" => 1}
  end

  @nba_fixtures Path.expand("fixtures/balldontlie", __DIR__)

  @doc """
  A balldontlie answer, decoded. `name` is a file in
  `test/support/fixtures/balldontlie` without `.json`: `teams`, `games_nyk`
  (the Knicks: six final games, a postponed one, two scheduled) and
  `games_lal_live` (the Lakers with a game in progress). They are written by
  hand from the documented shape; see that directory's README.
  """
  def nba_fixture(name) do
    @nba_fixtures |> Path.join("#{name}.json") |> File.read!() |> Jason.decode!()
  end

  @doc """
  Stubs `Knowseek.Cards.Balldontlie` HTTP calls (`Req.Test`): `/teams`, and
  `/games` of the Knicks (team id 20) and the Lakers (14, game in progress).
  Any other request is a 404. Pass `teams: body` (or `games_nyk:`,
  `games_lal_live:`) to replace a body; a function receives the conn and
  answers it. With `gate: true` every request first sends
  `{:nba_gated, pid}` and waits for `:go` sent to `pid`, so that a test
  controls when the upstream answers.

  Each request sends `{:nba_request, request, headers}` to the calling
  process: `request` is `"/teams"` or `"/games/<team id>"`, `headers` has
  `:user_agent`, `:authorization` and the `:params` of the query. The stub
  runs in the cache's fetch task, so the test must use shared mode:
  `setup :set_req_test_from_context` in a non-async test.
  """
  def stub_nba(overrides \\ []) do
    test_pid = self()
    gate? = Keyword.get(overrides, :gate, false)

    bodies =
      Map.new(
        [{"/teams", :teams}, {"/games/20", :games_nyk}, {"/games/14", :games_lal_live}],
        fn {request, name} ->
          {request, Keyword.get_lazy(overrides, name, fn -> nba_fixture(name) end)}
        end
      )

    Req.Test.stub(Knowseek.Cards.Balldontlie, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      request = nba_request(conn)

      headers = %{
        user_agent: List.first(Plug.Conn.get_req_header(conn, "user-agent")),
        authorization: List.first(Plug.Conn.get_req_header(conn, "authorization")),
        params: conn.query_params
      }

      send(test_pid, {:nba_request, request, headers})

      if gate? do
        send(test_pid, {:nba_gated, self()})

        receive do
          :go -> :ok
        end
      end

      case Map.fetch(bodies, request) do
        {:ok, fun} when is_function(fun, 1) -> fun.(conn)
        {:ok, body} -> Req.Test.json(conn, body)
        :error -> conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => "Not Found"})
      end
    end)
  end

  defp nba_request(%{request_path: "/v1/games", query_params: params}) do
    "/games/" <> Enum.join(List.wrap(params["team_ids"]), ",")
  end

  defp nba_request(%{request_path: path}), do: String.replace_prefix(path, "/v1", "")

  @open_meteo_fixtures Path.expand("fixtures/open_meteo", __DIR__)

  @doc """
  A recorded Open-Meteo forecast, decoded: `forecast_tokyo` (five days, recorded
  on 2026-11-01). See that directory's README.
  """
  def open_meteo_fixture(name) do
    @open_meteo_fixtures |> Path.join("#{name}.json") |> File.read!() |> Jason.decode!()
  end

  @doc """
  Stubs `Knowseek.Cards.OpenMeteo` HTTP calls (`Req.Test`) with `body` (default:
  the recorded Tokyo forecast; a function receives the conn and answers it). Each
  request sends `{:open_meteo_request, query_params, user_agent}` to the calling
  process. The stub runs in the cache's fetch task: shared mode (non-async test,
  `setup :set_req_test_from_context`).
  """
  def stub_open_meteo(body \\ nil) do
    test_pid = self()

    Req.Test.stub(Knowseek.Cards.OpenMeteo, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      user_agent = Plug.Conn.get_req_header(conn, "user-agent")
      send(test_pid, {:open_meteo_request, conn.query_params, user_agent})

      case body do
        nil -> Req.Test.json(conn, open_meteo_fixture("forecast_tokyo"))
        fun when is_function(fun, 1) -> fun.(conn)
        body -> Req.Test.json(conn, body)
      end
    end)
  end

  @doc """
  Empties the application's cache of the NBA team list (a day's TTL), so
  that a test sees the `/teams` request itself.
  """
  def reset_nba_teams_cache do
    :ok = Supervisor.terminate_child(Knowseek.Supervisor, Knowseek.Cards.NbaTeams)
    {:ok, _pid} = Supervisor.restart_child(Knowseek.Supervisor, Knowseek.Cards.NbaTeams)
    :ok
  end

  @sec_fixtures Path.expand("fixtures/sec_edgar", __DIR__)

  @doc """
  A decoded body from `test/support/fixtures/sec_edgar` without `.json`:
  `submissions_<nvda|aapl|googl|tsm>` and `shares_<nvda|aapl|tsm>`. See that
  directory's README for how they were recorded and trimmed.
  """
  def sec_fixture(name) do
    @sec_fixtures |> Path.join("#{name}.json") |> File.read!() |> Jason.decode!()
  end

  @sec_ciks %{
    "0001045810" => "nvda",
    "0000320193" => "aapl",
    "0001652044" => "googl",
    "0001046179" => "tsm"
  }

  @doc """
  Stubs `Knowseek.Cards.Edgar` HTTP calls (`Req.Test`) with the recorded
  answers: the submissions of Nvidia, Apple, Alphabet and TSMC (by CIK), the
  shares-outstanding concept of Nvidia, Apple and TSMC, and the recorded 404
  (XML) for the concept of Alphabet (which has none). Any other path is a 404.

  Options: `submissions: body` (for every company) and `shares: body` replace
  a body; `status: 403` (with `body:`, `headers:`) answers every request with
  that status instead.

  Each request sends `{:edgar_request, path, user_agent}` to the calling
  process. The stub runs in the cache's fetch task, so the test must use
  shared mode (`setup :set_req_test_from_context`, non-async).
  """
  def stub_edgar(overrides \\ []) do
    test_pid = self()

    Req.Test.stub(Knowseek.Cards.Edgar, fn conn ->
      user_agent = Plug.Conn.get_req_header(conn, "user-agent")
      send(test_pid, {:edgar_request, conn.request_path, user_agent})

      conn =
        Enum.reduce(Keyword.get(overrides, :headers, []), conn, fn {name, value}, conn ->
          Plug.Conn.put_resp_header(conn, name, value)
        end)

      case {Keyword.get(overrides, :status), edgar_body(conn.request_path, overrides)} do
        {nil, {:ok, body}} ->
          Req.Test.json(conn, body)

        {nil, :not_found} ->
          conn
          |> Plug.Conn.put_resp_content_type("application/xml")
          |> Plug.Conn.send_resp(
            404,
            File.read!(Path.join(@sec_fixtures, "concept_not_found.xml"))
          )

        {status, _body} ->
          conn
          |> Plug.Conn.put_resp_content_type("text/html")
          |> Plug.Conn.send_resp(status, Keyword.get(overrides, :body, "<html>blocked</html>"))
      end
    end)
  end

  defp edgar_body("/submissions/CIK" <> rest, overrides) do
    with [cik, "json"] <- String.split(rest, ".", parts: 2),
         {:ok, name} <- Map.fetch(@sec_ciks, cik) do
      {:ok,
       Keyword.get_lazy(overrides, :submissions, fn -> sec_fixture("submissions_#{name}") end)}
    else
      _no_company -> :not_found
    end
  end

  defp edgar_body("/api/xbrl/companyconcept/CIK" <> rest, overrides) do
    with [cik, "dei", "EntityCommonStockSharesOutstanding.json"] <- String.split(rest, "/"),
         {:ok, name} when name in ["nvda", "aapl", "tsm"] <- Map.fetch(@sec_ciks, cik) do
      {:ok, Keyword.get_lazy(overrides, :shares, fn -> sec_fixture("shares_#{name}") end)}
    else
      _no_concept -> :not_found
    end
  end

  defp edgar_body(_path, _overrides), do: :not_found

  @doc """
  A body long enough to be merged by content hash (see
  `Knowseek.Documents.min_alias_body_length/0`). Different `tag`s give
  different bodies.
  """
  def long_body(tag \\ "a") do
    "Article #{tag}. " <>
      String.duplicate("This sentence pads the body past the alias length floor. ", 8)
  end

  @doc """
  Logs a search through `Knowseek.Activity.record_search/4`, waits for the
  recorder, and returns the stored `Knowseek.Activity.SearchRecord`.

  Attrs: `:query`, `:coverage` (default `:none`), `:now`, and the hits, either
  as `:hits` (`%Knowseek.Search.Hit{}` structs) or as `:documents` (one hit per
  document: position 0, the document's origin, no passages).
  """
  def logged_search_fixture(attrs \\ %{}) do
    import Ecto.Query, only: [from: 2]

    attrs = Enum.into(attrs, %{})
    n = System.unique_integer([:positive])
    query = Map.get(attrs, :query, "logged search #{n}")

    hits =
      Map.get_lazy(attrs, :hits, fn ->
        for document <- Map.get(attrs, :documents, []) do
          %Knowseek.Search.Hit{
            document_id: document.id,
            position: 0,
            origin: document.origin,
            passages: []
          }
        end
      end)

    opts = if now = attrs[:now], do: [now: now], else: []
    :ok = Knowseek.Activity.record_search(query, Map.get(attrs, :coverage, :none), hits, opts)
    _ = :sys.get_state(Knowseek.Activity.Recorder)

    Knowseek.Repo.one!(
      from s in Knowseek.Activity.SearchRecord,
        where: s.query == ^query,
        order_by: [desc: s.id],
        limit: 1
    )
  end
end
