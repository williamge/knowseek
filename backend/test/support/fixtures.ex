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

  @wikidata_fixtures Path.expand("fixtures/wikidata", __DIR__)

  @doc """
  A recorded Wikidata API answer, decoded. `name` is a file in
  `test/support/fixtures/wikidata` without `.json`: `search_<query>` (a
  `wbsearchentities` answer for `knicks`, `nvidia`, `nvda`, `tokyo`, `texas`,
  `japan` or `apple`) or `entities_<query>` (the `wbgetentities` answer for the
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
    ~w(knicks nvidia nvda tokyo texas japan apple)
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
      ~w(knicks nvidia nvda tokyo texas japan apple)
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
    fixture = "search_#{String.downcase(search)}"

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

  @espn_fixtures Path.expand("fixtures/espn", __DIR__)

  @doc """
  A recorded ESPN answer, decoded. `name` is a file in
  `test/support/fixtures/espn` without `.json`: `teams`, `schedule_ny` (the
  Knicks: two final games, two scheduled), `roster_ny`, `schedule_lal_live`
  (the Lakers with a game in progress), `schedule_lal_live_noscore` (the same,
  recorded later, when ESPN listed the game in progress without scores),
  `summary_lal_live` (the scores and status of that game) and `roster_lal`. See that
  directory's README for how they were recorded and trimmed.
  """
  def espn_fixture(name) do
    @espn_fixtures |> Path.join("#{name}.json") |> File.read!() |> Jason.decode!()
  end

  @doc """
  Stubs `Knowseek.Cards.Espn` HTTP calls (`Req.Test`) with the recorded
  answers: the NBA `/teams` list, and the `/schedule` and `/roster` of the
  Knicks (team id 18) and the Lakers (13, game in progress). Any other path
  is a 404. Pass `schedule_ny: body` (or `roster_ny:`, `schedule_lal_live:`,
  `roster_lal:`, `summary_lal_live:`) to replace a body. With `gate: true` every request first
  sends `{:espn_gated, pid}` and waits for `:go` sent to `pid`, so that a test
  controls when the upstream answers.

  Each request sends `{:espn_request, path, user_agent}` to the calling
  process. The stub runs in the cache's fetch task, so the test must use
  shared mode: `setup :set_req_test_from_context` in a non-async test.
  """
  def stub_espn(overrides \\ []) do
    test_pid = self()
    gate? = Keyword.get(overrides, :gate, false)

    bodies =
      Map.new(
        [
          {"/basketball/nba/teams", :teams},
          {"/basketball/nba/teams/18/schedule", :schedule_ny},
          {"/basketball/nba/teams/18/roster", :roster_ny},
          {"/basketball/nba/teams/13/schedule", :schedule_lal_live},
          {"/basketball/nba/teams/13/roster", :roster_lal},
          {"/basketball/nba/summary", :summary_lal_live}
        ],
        fn {path, name} ->
          {path, Keyword.get_lazy(overrides, name, fn -> espn_fixture(name) end)}
        end
      )

    Req.Test.stub(Knowseek.Cards.Espn, fn conn ->
      user_agent = Plug.Conn.get_req_header(conn, "user-agent")
      path = String.replace_prefix(conn.request_path, "/apis/site/v2/sports", "")
      send(test_pid, {:espn_request, path, user_agent})

      if gate? do
        send(test_pid, {:espn_gated, self()})

        receive do
          :go -> :ok
        end
      end

      case Map.fetch(bodies, path) do
        {:ok, body} -> Req.Test.json(conn, body)
        :error -> conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"code" => 404})
      end
    end)
  end

  @doc """
  Empties the application's cache of the ESPN team list (a day's TTL), so
  that a test sees the `/teams` request itself.
  """
  def reset_espn_teams_cache do
    :ok = Supervisor.terminate_child(Knowseek.Supervisor, Knowseek.Cards.EspnTeams)
    {:ok, _pid} = Supervisor.restart_child(Knowseek.Supervisor, Knowseek.Cards.EspnTeams)
    :ok
  end

  @twelvedata_fixtures Path.expand("fixtures/twelvedata", __DIR__)

  @doc """
  A decoded body from `test/support/fixtures/twelvedata` without `.json`:
  `quote_aapl_closed`, `quote_aapl_open`, `quote_nvda_closed`,
  `error_401_demo` and `error_429`. See that directory's README for which
  were recorded and which were derived.
  """
  def twelvedata_fixture(name) do
    @twelvedata_fixtures |> Path.join("#{name}.json") |> File.read!() |> Jason.decode!()
  end

  @doc """
  Stubs `Knowseek.Cards.TwelveData` HTTP calls (`Req.Test`). `/quote` answers
  for `AAPL` and `NVDA` with `quote_aapl_closed` and `quote_nvda_closed`
  (pass `aapl: body` or `nvda: body` to replace one); any other symbol is a
  404. Pass `status: 429` (and `body:`, `headers:`) to answer every request
  with that status instead, for the failure paths.

  Each request sends `{:twelvedata_request, path, query_params, authorization}`
  to the calling process. The stub runs in the cache's fetch task, so the test
  must use shared mode (`setup :set_req_test_from_context`, non-async).
  """
  def stub_twelvedata(overrides \\ []) do
    test_pid = self()

    bodies = %{
      "AAPL" =>
        Keyword.get_lazy(overrides, :aapl, fn -> twelvedata_fixture("quote_aapl_closed") end),
      "NVDA" =>
        Keyword.get_lazy(overrides, :nvda, fn -> twelvedata_fixture("quote_nvda_closed") end)
    }

    Req.Test.stub(Knowseek.Cards.TwelveData, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      authorization = Plug.Conn.get_req_header(conn, "authorization")
      send(test_pid, {:twelvedata_request, conn.request_path, conn.query_params, authorization})

      conn =
        Enum.reduce(Keyword.get(overrides, :headers, []), conn, fn {name, value}, conn ->
          Plug.Conn.put_resp_header(conn, name, value)
        end)

      case {Keyword.get(overrides, :status), Map.fetch(bodies, conn.query_params["symbol"])} do
        {nil, {:ok, body}} ->
          Req.Test.json(conn, body)

        {nil, :error} ->
          conn
          |> Plug.Conn.put_status(404)
          |> Req.Test.json(%{"code" => 404, "status" => "error"})

        {status, _bodies} ->
          conn
          |> Plug.Conn.put_status(status)
          |> Req.Test.json(
            Keyword.get(overrides, :body, %{"code" => status, "status" => "error"})
          )
      end
    end)
  end

  @doc """
  A body long enough to be merged by content hash (see
  `Knowseek.Documents.min_alias_body_length/0`). Different `tag`s give
  different bodies.
  """
  def long_body(tag \\ "a") do
    "Article #{tag}. " <>
      String.duplicate("This sentence pads the body past the alias length floor. ", 8)
  end
end
