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
