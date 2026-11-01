defmodule Knowseek.Cards.Providers.TwelveDataCompanyTest do
  # The Twelve Data stub runs in the provider's calling process, but Wikidata's
  # in no task here: shared mode keeps the helpers uniform with the other
  # provider tests.
  use ExUnit.Case, async: false

  import Knowseek.Fixtures
  import Req.Test, only: [set_req_test_from_context: 1]

  alias Knowseek.Cards.Providers.TwelveDataCompany
  alias Knowseek.Entities.{Entity, Wikidata}

  setup :set_req_test_from_context

  @nasdaq "Q82059"
  @nyse "Q13677"

  defp nvidia, do: company("Nvidia", [%{exchange: @nasdaq, ticker: "NVDA"}])

  defp company(label, tickers) do
    %Entity{
      id: "Q-" <> label,
      label: label,
      types: ["Q891723", "Q4830453"],
      exchange_tickers: tickers
    }
  end

  describe "handles?/1" do
    test "a company on Nasdaq or the NYSE" do
      assert TwelveDataCompany.handles?(nvidia())
      assert TwelveDataCompany.handles?(company("JPMorgan", [%{exchange: @nyse, ticker: "JPM"}]))
    end

    test "the recorded Wikidata items for nvda and nvidia" do
      stub_wikidata()

      for query <- ["nvda", "nvidia"] do
        {:ok, candidates} = Wikidata.search(query, [])
        assert Enum.any?(candidates, &TwelveDataCompany.handles?/1)
      end
    end

    test "another exchange is not handled" do
      refute TwelveDataCompany.handles?(company("Sony", [%{exchange: "Q217475", ticker: "6758"}]))
    end

    test "the first supported listing wins, unsupported ones are skipped" do
      entity =
        company("Both", [
          %{exchange: "Q217475", ticker: "6758"},
          %{exchange: @nyse, ticker: "SONY"},
          %{exchange: @nasdaq, ticker: "XYZ"}
        ])

      assert {"SONY", {"NYSE", "NYSE"}} = TwelveDataCompany.listing(entity)
    end

    test "a company with no exchange ticker, and a non-company, are not handled" do
      refute TwelveDataCompany.handles?(company("No Ticker", []))

      refute TwelveDataCompany.handles?(%Entity{
               id: "Q1",
               label: "Tokyo",
               types: ["Q515"],
               exchange_tickers: [%{exchange: @nasdaq, ticker: "TKY"}]
             })
    end

    test "with no API key nothing is handled" do
      with_env(api_key: nil, fun: fn -> refute TwelveDataCompany.handles?(nvidia()) end)
      with_env(api_key: "  ", fun: fn -> refute TwelveDataCompany.handles?(nvidia()) end)
    end
  end

  describe "fetch/1" do
    test "a closed market: the facts of the recorded-shape quote" do
      stub_twelvedata()

      assert {:ok, %{type: "company", title: "NVIDIA Corp", facts: facts}, ttl} =
               TwelveDataCompany.fetch(nvidia())

      assert facts == %{
               source: "Twelve Data",
               symbol: "NVDA",
               exchange: "Nasdaq",
               currency: "USD",
               price: 204.64,
               previous_close: 213.66,
               change: -9.02,
               percent_change: -4.22,
               market_state: "closed",
               quote_time: ~U[2026-10-30 20:00:00Z],
               delayed: false
             }

      assert ttl in 60_000..3_600_000
    end

    test "the request: symbol, exchange, key in the header and not in the URL" do
      stub_twelvedata()
      assert {:ok, _card, _ttl} = TwelveDataCompany.fetch(nvidia())

      assert_received {:twelvedata_request, "/quote", params, ["apikey test-key"]}
      assert params == %{"symbol" => "NVDA", "exchange" => "NASDAQ"}
    end

    test "an open market has the 60 s TTL and the recorded AAPL fields" do
      stub_twelvedata(aapl: twelvedata_fixture("quote_aapl_open"))
      apple = company("Apple", [%{exchange: @nasdaq, ticker: "AAPL"}])

      assert {:ok, %{title: "Apple Inc.", facts: facts}, 60_000} = TwelveDataCompany.fetch(apple)
      assert %{market_state: "open", price: 350.02, change: 1.11, percent_change: 0.32} = facts
    end

    test "the recorded AAPL body (closed, down)" do
      stub_twelvedata()
      apple = company("Apple", [%{exchange: @nasdaq, ticker: "AAPL"}])

      assert {:ok, %{facts: facts}, _ttl} = TwelveDataCompany.fetch(apple)

      assert %{
               price: 344.63,
               previous_close: 348.91,
               change: -4.28,
               percent_change: -1.23,
               market_state: "closed",
               quote_time: ~U[2026-10-30 19:59:00Z]
             } = facts
    end

    test "an unsupported exchange is an error, with no request" do
      stub_twelvedata()
      sony = company("Sony", [%{exchange: "Q217475", ticker: "6758"}])

      assert {:error, :unsupported_exchange} = TwelveDataCompany.fetch(sony)
      refute_received {:twelvedata_request, _, _, _}
    end

    test "HTTP 429 is a rate limit that stops fetching for a minute by default" do
      stub_twelvedata(status: 429, body: twelvedata_fixture("error_429"))
      assert {:error, {:rate_limited, 60_000}} = TwelveDataCompany.fetch(nvidia())
    end

    test "Retry-After is honoured" do
      stub_twelvedata(status: 429, headers: [{"retry-after", "17"}])
      assert {:error, {:rate_limited, 17_000}} = TwelveDataCompany.fetch(nvidia())
    end

    test "a 429 in the body of a 200 is a rate limit too" do
      stub_twelvedata(nvda: twelvedata_fixture("error_429"))
      assert {:error, {:rate_limited, 60_000}} = TwelveDataCompany.fetch(nvidia())
    end

    test "a rejected key is an error, not a card" do
      stub_twelvedata(status: 401, body: twelvedata_fixture("error_401_demo"))
      assert {:error, {:http_status, 401}} = TwelveDataCompany.fetch(nvidia())

      stub_twelvedata(nvda: twelvedata_fixture("error_401_demo"))
      assert {:error, {:twelve_data, 401}} = TwelveDataCompany.fetch(nvidia())
    end

    test "an HTTP error is an error" do
      stub_twelvedata(status: 503)
      assert {:error, {:http_status, 503}} = TwelveDataCompany.fetch(nvidia())
    end

    test "malformed bodies are errors" do
      good = twelvedata_fixture("quote_nvda_closed")

      for body <- [
            %{},
            %{"symbol" => "NVDA"},
            %{good | "close" => nil},
            %{good | "close" => "N/A"},
            %{good | "previous_close" => "abc"},
            Map.delete(good, "is_market_open"),
            %{good | "is_market_open" => "yes"}
          ] do
        stub_twelvedata(nvda: body)
        assert {:error, :malformed_quote} = TwelveDataCompany.fetch(nvidia())
      end
    end

    test "a body that is not a JSON object is an error" do
      Req.Test.stub(Knowseek.Cards.TwelveData, fn conn -> Req.Test.json(conn, [1, 2]) end)
      assert {:error, :unexpected_body} = TwelveDataCompany.fetch(nvidia())
    end

    test "a failed connection is an error" do
      Req.Test.stub(Knowseek.Cards.TwelveData, &Req.Test.transport_error(&1, :econnrefused))
      assert {:error, %Req.TransportError{}} = TwelveDataCompany.fetch(nvidia())
    end

    test "a missing change is computed from the previous close" do
      body = Map.drop(twelvedata_fixture("quote_nvda_closed"), ["change", "percent_change"])
      stub_twelvedata(nvda: body)

      assert {:ok, %{facts: %{change: -9.02, percent_change: -4.22}}, _ttl} =
               TwelveDataCompany.fetch(nvidia())
    end

    test "no API key is an error with no request" do
      stub_twelvedata()

      with_env(
        api_key: nil,
        fun: fn -> assert {:error, :no_api_key} = TwelveDataCompany.fetch(nvidia()) end
      )

      refute_received {:twelvedata_request, _, _, _}
    end
  end

  describe "ttl/2" do
    test "open: 60 s whatever the time" do
      assert TwelveDataCompany.ttl(%{market_state: "open"}, ~U[2026-10-30 15:00:00Z]) == 60_000
    end

    test "closed, far from the next open: capped at an hour" do
      # Friday 16:30 New York (EDT).
      assert TwelveDataCompany.ttl(%{market_state: "closed"}, ~U[2026-10-30 20:30:00Z]) ==
               3_600_000
    end

    test "closed, a short time before the open: until two minutes before it" do
      # Monday 2026-11-02 09:00 EST (14:00 UTC): 30 minutes to the open.
      assert TwelveDataCompany.ttl(%{market_state: "closed"}, ~U[2026-11-02 14:00:00Z]) ==
               28 * 60_000
    end

    test "closed, a minute before the open: never below a minute" do
      assert TwelveDataCompany.ttl(%{market_state: "closed"}, ~U[2026-11-02 14:29:00Z]) == 60_000
    end

    test "open and closed differ" do
      now = ~U[2026-10-30 20:30:00Z]

      refute TwelveDataCompany.ttl(%{market_state: "open"}, now) ==
               TwelveDataCompany.ttl(%{market_state: "closed"}, now)
    end
  end

  describe "next_open/1" do
    test "before 09:30 on a weekday it is today; after, the next weekday" do
      # Monday 2026-11-02, EST (UTC-5): 09:30 is 14:30 UTC.
      assert TwelveDataCompany.next_open(~U[2026-11-02 13:00:00Z]) == ~U[2026-11-02 14:30:00Z]
      assert TwelveDataCompany.next_open(~U[2026-11-02 14:30:00Z]) == ~U[2026-11-03 14:30:00Z]
    end

    test "Friday evening and the weekend give Monday" do
      # Friday 2026-10-30 is still EDT (UTC-4); Monday 2026-11-02 is EST.
      assert TwelveDataCompany.next_open(~U[2026-10-30 22:00:00Z]) == ~U[2026-11-02 14:30:00Z]
      assert TwelveDataCompany.next_open(~U[2026-11-01 12:00:00Z]) == ~U[2026-11-02 14:30:00Z]
    end

    test "summer time: 09:30 is 13:30 UTC" do
      assert TwelveDataCompany.next_open(~U[2026-07-01 10:00:00Z]) == ~U[2026-07-01 13:30:00Z]
    end

    test "the clocks changing between now and the open" do
      # Saturday 2026-03-07 (EST) to Monday 2026-03-09 (EDT; changed on the 8th).
      assert TwelveDataCompany.next_open(~U[2026-03-07 18:00:00Z]) == ~U[2026-03-09 13:30:00Z]
    end
  end

  defp with_env(opts) do
    {fun, config} = Keyword.pop!(opts, :fun)
    previous = Application.fetch_env!(:knowseek, Knowseek.Cards.TwelveData)
    Application.put_env(:knowseek, Knowseek.Cards.TwelveData, Keyword.merge(previous, config))

    try do
      fun.()
    after
      Application.put_env(:knowseek, Knowseek.Cards.TwelveData, previous)
    end
  end
end
