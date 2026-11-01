defmodule KnowseekWeb.Plugs.RateLimitTest do
  # Turns the limit on through the application environment, which is global:
  # not async, so no other test runs while it is on.
  use KnowseekWeb.ConnCase, async: false

  alias Knowseek.{Cache, RateLimiter}
  alias Knowseek.Entities.{BlockingResolver, FakeResolver}

  @start_ms 1_000_000
  @client_a {203, 0, 113, 1}
  @client_b {203, 0, 113, 2}

  setup do
    clock = start_supervised!({Agent, fn -> @start_ms end})
    limiter = :"rate_limit_test_limiter_#{System.unique_integer([:positive])}"

    start_supervised!(
      {RateLimiter,
       name: limiter, clock: fn -> Agent.get(clock, & &1) end, sweep_interval: :infinity}
    )

    entities = :"rate_limit_test_entities_#{System.unique_integer([:positive])}"
    start_supervised!({Cache, name: entities, max_in_flight: 4})
    cards = :"rate_limit_test_cards_#{System.unique_integer([:positive])}"
    start_supervised!({Cache, name: cards})

    previous = Application.get_env(:knowseek, KnowseekWeb.RateLimit)

    configure(
      enabled: true,
      limiter: limiter,
      limits: [cards: {3, 60_000}, search: {3, 60_000}, documents: {3, 60_000}],
      trusted_proxies: []
    )

    Application.put_env(:knowseek, KnowseekWeb.CardController,
      entities: [cache: entities, resolver: FakeResolver],
      cards: [cache: cards, providers: [Knowseek.Cards.StaticProvider]]
    )

    on_exit(fn ->
      Application.put_env(:knowseek, KnowseekWeb.RateLimit, previous)
      Application.delete_env(:knowseek, KnowseekWeb.CardController)
    end)

    {:ok, clock: clock, limiter: limiter, entities: entities, cards: cards}
  end

  defp configure(overrides) do
    current = Application.get_env(:knowseek, KnowseekWeb.RateLimit)
    Application.put_env(:knowseek, KnowseekWeb.RateLimit, Keyword.merge(current, overrides))
  end

  defp advance(clock, ms), do: Agent.update(clock, &(&1 + ms))

  defp from(conn, ip), do: %{conn | remote_ip: ip}

  defp card_status(conn, ip, q \\ "fake") do
    conn |> from(ip) |> get(~p"/api/cards", q: q) |> Map.fetch!(:status)
  end

  defp search_status(conn, ip, query \\ "kelp forests") do
    conn |> from(ip) |> post(~p"/api/search", query: query) |> Map.fetch!(:status)
  end

  defp document_status(conn, ip) do
    conn
    |> from(ip)
    |> post(~p"/api/documents", document: %{body: "Kelp forests grow along cold coasts."})
    |> Map.fetch!(:status)
  end

  describe "GET /api/cards" do
    test "answers 429 with Retry-After over the limit, then recovers", %{conn: conn, clock: clock} do
      assert for(_ <- 1..3, do: card_status(conn, @client_a)) == [200, 200, 200]

      limited = conn |> from(@client_a) |> get(~p"/api/cards", q: "fake")
      assert json_response(limited, 429) == %{"errors" => %{"detail" => "Too many requests"}}
      # 3 requests a minute: one token every 20 s.
      assert get_resp_header(limited, "retry-after") == ["20"]
      assert [content_type] = get_resp_header(limited, "content-type")
      assert content_type =~ "application/json"

      advance(clock, 19_000)

      assert conn
             |> from(@client_a)
             |> get(~p"/api/cards", q: "fake")
             |> get_resp_header("retry-after") ==
               ["1"]

      advance(clock, 1_000)
      assert card_status(conn, @client_a) == 200
      assert card_status(conn, @client_a) == 429
    end

    test "a request over the limit reaches no cache", %{conn: conn, entities: entities} do
      for _ <- 1..3, do: card_status(conn, @client_a)
      assert 429 == card_status(conn, @client_a, "something else")

      :ok = Knowseek.Entities.await("fake", cache: entities, resolver: FakeResolver)
      :ok = Knowseek.Entities.await("something else", cache: entities, resolver: FakeResolver)
      assert %{entries: 1} = Cache.stats(entities)
    end

    test "another client is not affected", %{conn: conn} do
      for _ <- 1..3, do: card_status(conn, @client_a)

      assert card_status(conn, @client_a) == 429
      assert card_status(conn, @client_b) == 200
    end

    test "a flood of distinct junk queries from one client is cut off at the limit, while a second client is served",
         %{conn: conn, entities: entities, cards: cards} do
      statuses = for n <- 1..100, do: card_status(conn, @client_a, "junk query #{n}")

      # The limit is a burst of 3 and no time passes: 3 reach the cache.
      assert Enum.take(statuses, 3) == [200, 200, 200]
      assert Enum.all?(Enum.drop(statuses, 3), &(&1 == 429))

      for n <- 1..3,
          do:
            :ok =
              Knowseek.Entities.await("junk query #{n}", cache: entities, resolver: FakeResolver)

      assert %{entries: 3} = Cache.stats(entities)

      # The second client is not affected: its real query resolves and its card
      # arrives (three requests: the entity, the card, the card again).
      options = [cache: entities, resolver: FakeResolver]
      assert card_status(conn, @client_b, "fake") == 200
      :ok = Knowseek.Entities.await("fake", options)
      assert card_status(conn, @client_b, "fake") == 200
      {:ok, %{entity: entity}} = Knowseek.Entities.resolve("fake", options)
      :ok = Knowseek.Cards.await(entity, cache: cards, providers: [Knowseek.Cards.StaticProvider])

      data = conn |> from(@client_b) |> get(~p"/api/cards", q: "fake") |> json_response(200)
      assert %{"status" => "fresh", "entity" => %{"label" => "Fake Team"}} = data["data"]
    end
  end

  test "a flood from one client does not keep another client's query pending (capped cache, blocking resolver)",
       %{conn: conn} do
    configure(limits: [cards: {2, 60_000}, search: {3, 60_000}, documents: {3, 60_000}])
    BlockingResolver.register()
    capped = :"rate_limit_test_capped_#{System.unique_integer([:positive])}"
    start_supervised!({Cache, name: capped, max_in_flight: 4, reserve_for_refresh: 1})

    Application.put_env(:knowseek, KnowseekWeb.CardController,
      entities: [cache: capped, resolver: BlockingResolver]
    )

    # Client A floods with 50 distinct junk queries: 2 get through and block in
    # the resolver, 48 are answered 429 and start nothing.
    statuses = for n <- 1..50, do: card_status(conn, @client_a, "junk #{n}")
    assert Enum.count(statuses, &(&1 == 200)) == 2
    assert Enum.count(statuses, &(&1 == 429)) == 48
    assert_receive {:resolving, junk_one, "junk 1"}
    assert_receive {:resolving, junk_two, "junk 2"}
    refute_receive {:resolving, _, _}, 20
    assert %{in_flight: 2} = Cache.stats(capped)

    # Client B's query starts at once, with both junk resolutions still blocked.
    assert card_status(conn, @client_b, "real query") == 200
    assert_receive {:resolving, real, "real query"}

    for pid <- [junk_one, junk_two, real], do: send(pid, :release)
    :ok = Knowseek.Entities.await("real query", cache: capped, resolver: BlockingResolver)

    assert :none ==
             Knowseek.Entities.resolve("real query", cache: capped, resolver: BlockingResolver)
  end

  describe "POST /api/search" do
    test "answers 429 with Retry-After over the limit and enqueues nothing", %{
      conn: conn,
      clock: clock
    } do
      statuses = for n <- 1..3, do: search_status(conn, @client_a, "kelp forests #{n}")
      assert statuses == [200, 200, 200]
      assert length(all_enqueued(worker: Knowseek.Discovery.SeekWorker)) == 3

      limited = conn |> from(@client_a) |> post(~p"/api/search", query: "kelp forests 4")
      assert json_response(limited, 429) == %{"errors" => %{"detail" => "Too many requests"}}
      assert get_resp_header(limited, "retry-after") == ["20"]
      assert length(all_enqueued(worker: Knowseek.Discovery.SeekWorker)) == 3

      advance(clock, 20_000)
      assert search_status(conn, @client_a, "kelp forests 5") == 200
    end

    test "another client is not affected", %{conn: conn} do
      for _ <- 1..3, do: search_status(conn, @client_a)

      assert search_status(conn, @client_a) == 429
      assert search_status(conn, @client_b) == 200
    end

    test "a bad request counts too: it costs the server a parse", %{conn: conn} do
      for _ <- 1..3, do: assert(search_status(conn, @client_a, " ") == 400)
      assert search_status(conn, @client_a, " ") == 429
    end
  end

  describe "POST /api/documents" do
    test "answers 429 with Retry-After over the limit and stores nothing more", %{
      conn: conn,
      clock: clock
    } do
      assert for(_ <- 1..3, do: document_status(conn, @client_a)) == [201, 201, 201]

      limited =
        conn
        |> from(@client_a)
        |> post(~p"/api/documents", document: %{body: "A second body of text."})

      assert json_response(limited, 429) == %{"errors" => %{"detail" => "Too many requests"}}
      assert get_resp_header(limited, "retry-after") == ["20"]

      advance(clock, 20_000)
      assert document_status(conn, @client_a) == 201
    end

    test "reading documents is not limited", %{conn: conn} do
      for _ <- 1..3, do: document_status(conn, @client_a)
      assert document_status(conn, @client_a) == 429

      for _ <- 1..10 do
        assert conn |> from(@client_a) |> get(~p"/api/documents") |> Map.fetch!(:status) == 200
      end
    end
  end

  describe "budgets and exemptions" do
    test "each endpoint has its own budget", %{conn: conn} do
      for _ <- 1..3, do: card_status(conn, @client_a)
      assert card_status(conn, @client_a) == 429

      assert search_status(conn, @client_a) == 200
      assert document_status(conn, @client_a) == 201
    end

    test "limits come from the configuration", %{conn: conn} do
      configure(limits: [cards: {1, 60_000}, search: {1, 60_000}, documents: {1, 60_000}])

      assert card_status(conn, @client_a) == 200
      assert card_status(conn, @client_a) == 429
    end

    test "GET /api/health is never limited", %{conn: conn} do
      configure(limits: [cards: {1, 60_000}, search: {1, 60_000}, documents: {1, 60_000}])

      for _ <- 1..20 do
        assert conn |> from(@client_a) |> get(~p"/api/health") |> Map.fetch!(:status) == 200
      end
    end

    test "enabled: false turns the limit off", %{conn: conn} do
      configure(enabled: false)
      assert for(_ <- 1..10, do: card_status(conn, @client_a)) == List.duplicate(200, 10)
    end
  end

  describe "before the body is read" do
    defp json_post(conn, ip, path, body) do
      conn |> from(ip) |> put_req_header("content-type", "application/json") |> post(path, body)
    end

    test "a client over its limit is answered 429 without its body being parsed", %{conn: conn} do
      for _ <- 1..3, do: assert(search_status(conn, @client_a) == 200)

      # A body that is not JSON would raise in `Plug.Parsers`; one over the length
      # limit would be a 413. Neither is looked at.
      limited = json_post(conn, @client_a, ~p"/api/search", "{ this is not json")
      assert json_response(limited, 429) == %{"errors" => %{"detail" => "Too many requests"}}

      limited = json_post(conn, @client_a, ~p"/api/search", String.duplicate("a", 2_000_000))
      assert limited.status == 429
      assert get_resp_header(limited, "retry-after") == ["20"]
    end

    test "a request under its limit still has its body parsed", %{conn: conn} do
      assert_raise Plug.Parsers.ParseError, fn ->
        json_post(conn, @client_a, ~p"/api/search", "{ this is not json")
      end
    end

    test "a body over the 1 MB limit is a 413, for a client under its limit", %{conn: conn} do
      assert_error_sent 413, fn ->
        json_post(conn, @client_a, ~p"/api/documents", String.duplicate("a", 1_000_001))
      end
    end

    test "a document of 900 thousand characters is accepted", %{conn: conn} do
      body = %{
        document: %{body: String.duplicate("kelp forests grow along cold coasts. ", 24_000)}
      }

      assert conn |> from(@client_a) |> post(~p"/api/documents", body) |> Map.fetch!(:status) ==
               201
    end

    test "HEAD /api/cards runs the controller as a GET, so it draws on the cards budget", %{
      conn: conn
    } do
      statuses =
        for _ <- 1..5,
            do: conn |> from(@client_a) |> head(~p"/api/cards?q=fake") |> Map.fetch!(:status)

      assert statuses == [200, 200, 200, 429, 429]
      assert card_status(conn, @client_a) == 429
    end

    test "bucket/1 names the limited routes and nothing else" do
      bucket = fn method, path ->
        %{Plug.Test.conn(method, path) | path_info: String.split(path, "/", trim: true)}
        |> KnowseekWeb.Plugs.RateLimit.bucket()
      end

      assert bucket.("GET", "/api/cards") == :cards
      assert bucket.("HEAD", "/api/cards") == :cards
      assert bucket.("POST", "/api/search") == :search
      assert bucket.("POST", "/api/documents") == :documents

      for {method, path} <- [
            {"POST", "/api/cards"},
            {"GET", "/api/search"},
            {"GET", "/api/documents"},
            {"GET", "/api/documents/1"},
            {"POST", "/api/documents/1"},
            {"GET", "/api/health"},
            {"GET", "/"}
          ] do
        assert bucket.(method, path) == nil, "#{method} #{path}"
      end
    end
  end

  describe "who the client is" do
    test "X-Forwarded-For does not change the client when no proxy is trusted", %{conn: conn} do
      statuses =
        for n <- 1..6 do
          conn
          |> from(@client_a)
          |> put_req_header("x-forwarded-for", "198.51.100.#{n}")
          |> get(~p"/api/cards", q: "fake")
          |> Map.fetch!(:status)
        end

      assert statuses == [200, 200, 200, 429, 429, 429]
    end

    test "behind a trusted proxy, the forwarded address is the client", %{conn: conn} do
      configure(trusted_proxies: ["10.0.0.0/8"])
      proxy = {10, 0, 0, 1}

      forwarded = fn ip ->
        conn
        |> from(proxy)
        |> put_req_header("x-forwarded-for", ip)
        |> get(~p"/api/cards", q: "fake")
        |> Map.fetch!(:status)
      end

      assert for(_ <- 1..3, do: forwarded.("198.51.100.1")) == [200, 200, 200]
      assert forwarded.("198.51.100.1") == 429
      # Another client behind the same proxy has its own budget.
      assert forwarded.("198.51.100.2") == 200
    end

    test "behind a trusted proxy, a header the client wrote does not pick its bucket", %{
      conn: conn
    } do
      configure(trusted_proxies: ["10.0.0.0/8"])

      statuses =
        for n <- 1..5 do
          conn
          |> from({10, 0, 0, 1})
          # The client wrote the first entry; the proxy appended the second.
          |> put_req_header("x-forwarded-for", "192.0.2.#{n}, 198.51.100.1")
          |> get(~p"/api/cards", q: "fake")
          |> Map.fetch!(:status)
        end

      assert statuses == [200, 200, 200, 429, 429]
    end

    test "a trusted proxy setting does not make other sockets trusted", %{conn: conn} do
      configure(trusted_proxies: ["10.0.0.0/8"])

      statuses =
        for n <- 1..5 do
          conn
          |> from(@client_a)
          |> put_req_header("x-forwarded-for", "192.0.2.#{n}")
          |> get(~p"/api/cards", q: "fake")
          |> Map.fetch!(:status)
        end

      assert statuses == [200, 200, 200, 429, 429]
    end
  end
end
