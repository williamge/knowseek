defmodule Knowseek.Cards.Providers.CompanyTest do
  # The EDGAR stub runs in tasks of the provider, so Req.Test is shared.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Knowseek.Fixtures
  import Req.Test, only: [set_req_test_from_context: 1]

  alias Knowseek.Cards.Providers.Company
  alias Knowseek.Entities.{Entity, Wikidata}

  setup :set_req_test_from_context

  @nvidia_cik "0001045810"

  defp company(label, cik, attrs \\ []) do
    struct!(
      %Entity{
        id: "Q-" <> label,
        label: label,
        types: ["Q891723", "Q4830453"],
        exchange_tickers: [%{exchange: "Q82059", ticker: "X"}],
        cik: cik
      },
      attrs
    )
  end

  defp nvidia, do: company("Nvidia", @nvidia_cik)

  defp requests(acc \\ []) do
    receive do
      {:edgar_request, path, user_agent} -> requests([{path, user_agent} | acc])
    after
      20 -> Enum.reverse(acc)
    end
  end

  describe "handles?/1" do
    test "a company with a CIK" do
      assert Company.handles?(nvidia())
    end

    test "the recorded Wikidata items for nvda, nvidia and apple" do
      stub_wikidata()

      for query <- ["nvda", "nvidia", "apple"] do
        {:ok, candidates} = Wikidata.search(query, [])
        assert Enum.any?(candidates, &Company.handles?/1), query
      end
    end

    test "a company with no CIK is not handled" do
      refute Company.handles?(company("No Cik", nil))
    end

    test "a company on an exchange that is not in the US is handled when it has a CIK" do
      abroad =
        company("TSMC", "0001046179", exchange_tickers: [%{exchange: "Q217475", ticker: "2330"}])

      assert Company.handles?(abroad)
    end

    test "a CIK on something that is not a company is not handled" do
      refute Company.handles?(%Entity{
               id: "Q1",
               label: "Tokyo",
               types: ["Q515"],
               exchange_tickers: [%{exchange: "Q82059", ticker: "TKY"}],
               cik: @nvidia_cik
             })
    end
  end

  describe "fetch/1" do
    test "the facts of the recorded Nvidia answers" do
      stub_edgar()

      assert {:ok, %{type: "company", title: "Nvidia", facts: facts}, 3_600_000} =
               Company.fetch(nvidia())

      assert %{
               source: "SEC EDGAR",
               source_url:
                 "https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=0001045810",
               legal_name: "NVIDIA CORP",
               cik: "0001045810",
               listings: [%{ticker: "NVDA", exchange: "Nasdaq"}],
               industry: "Semiconductors & Related Devices",
               category: "Large accelerated filer",
               fiscal_year_end: %{month: 1, day: 31},
               shares_outstanding: %{value: 24_100_000_000, as_of: "2026-08-21"}
             } = facts

      # Forms 4 and 144 are not listed; the five latest 8-K/10-Q/10-K are.
      assert [first | _] = facts.filings
      assert length(facts.filings) == 5
      assert Enum.all?(facts.filings, &(&1.form in ["8-K", "10-Q", "10-K"]))

      assert first == %{
               form: "8-K",
               filed: "2026-09-03",
               report_date: "2026-09-02",
               items: ["8.01"],
               description: "8-K",
               url:
                 "https://www.sec.gov/Archives/edgar/data/1045810/000104581026000078/nvda-20260902.htm"
             }

      assert Enum.at(facts.filings, 1) |> Map.take([:form, :filed, :report_date, :items]) ==
               %{form: "10-Q", filed: "2026-08-26", report_date: "2026-07-26", items: []}

      assert Enum.at(facts.filings, 2).items == ["2.02", "9.01"]
    end

    test "the requests: two, to data.sec.gov paths, with the default User-Agent" do
      stub_edgar()
      assert {:ok, _card, _ttl} = Company.fetch(nvidia())

      assert [
               {"/api/xbrl/companyconcept/CIK0001045810/dei/EntityCommonStockSharesOutstanding.json",
                ua1},
               {"/submissions/CIK0001045810.json", ua2}
             ] = Enum.sort(requests())

      assert ua1 == ["Knowseek/0.1 (self-hosted instance)"]
      assert ua2 == ["Knowseek/0.1 (self-hosted instance)"]
    end

    test "a configured User-Agent is sent" do
      stub_edgar()

      with_edgar_config([user_agent: "Acme Corp ops@acme.example"], fn ->
        assert {:ok, _card, _ttl} = Company.fetch(nvidia())
      end)

      assert [{_, ["Acme Corp ops@acme.example"]}, {_, ["Acme Corp ops@acme.example"]}] =
               requests()
    end

    test "a company with no shares concept (404, Alphabet) still has a card" do
      stub_edgar()
      alphabet = company("Alphabet", "0001652044")

      assert {:ok, %{facts: facts}, _ttl} = Company.fetch(alphabet)
      assert facts.shares_outstanding == nil
      assert facts.legal_name == "Alphabet Inc."

      assert Enum.map(facts.listings, & &1.ticker) == ["GOOGL", "GOOG", "GOOGM", "GOOGN"]
      assert length(facts.filings) == 5
    end

    test "a foreign filer: 6-K and 20-F filings, NYSE listing" do
      stub_edgar()

      assert {:ok, %{facts: facts}, _ttl} = Company.fetch(company("TSMC", "0001046179"))
      assert %{ticker: "TSM", exchange: "NYSE"} = hd(facts.listings)
      assert Enum.all?(facts.filings, &(&1.form in ["6-K", "20-F"]))
      assert facts.shares_outstanding.value > 0
    end

    test "a title falls back to the SEC name" do
      stub_edgar()

      assert {:ok, %{title: "NVIDIA CORP"}, _ttl} = Company.fetch(%{nvidia() | label: nil})
    end

    test "a shares failure other than a block does not fail the card" do
      Req.Test.stub(Knowseek.Cards.Edgar, fn conn ->
        if String.contains?(conn.request_path, "companyconcept"),
          do: Plug.Conn.send_resp(conn, 500, "oops"),
          else: Req.Test.json(conn, sec_fixture("submissions_nvda"))
      end)

      assert {:ok, %{facts: %{shares_outstanding: nil, legal_name: "NVIDIA CORP"}}, _ttl} =
               Company.fetch(nvidia())
    end

    test "HTTP 429 is a rate limit, with Retry-After" do
      stub_edgar(status: 429, headers: [{"retry-after", "17"}])
      assert {:error, {:rate_limited, 17_000}} = Company.fetch(nvidia())
    end

    test "HTTP 403 stops fetching for ten minutes and logs one warning about SEC_USER_AGENT" do
      stub_edgar(status: 403, body: "<title>Undeclared Automated Tool</title>")

      log =
        capture_log(fn ->
          assert {:error, {:rate_limited, 600_000}} = Company.fetch(nvidia())
        end)

      assert log =~ "SEC_USER_AGENT"
      assert length(Regex.scan(~r/answered HTTP 403/, log)) == 1
    end

    test "an HTTP error and a failed connection are errors" do
      stub_edgar(status: 503)
      assert {:error, {:http_status, 503}} = Company.fetch(nvidia())

      Req.Test.stub(Knowseek.Cards.Edgar, &Req.Test.transport_error(&1, :econnrefused))
      assert {:error, %Req.TransportError{}} = Company.fetch(nvidia())
    end

    test "a company the SEC does not know (404) is an error" do
      stub_edgar()
      assert {:error, :not_found} = Company.fetch(company("Ghost", "0009999999"))
    end

    test "malformed submissions are an error" do
      for body <- [%{}, %{"name" => nil}, %{"filings" => %{}}] do
        stub_edgar(submissions: body)
        assert {:error, :malformed_submissions} = Company.fetch(nvidia())
      end
    end

    test "a body that is not a JSON object is an error" do
      Req.Test.stub(Knowseek.Cards.Edgar, fn conn -> Req.Test.json(conn, [1, 2]) end)
      assert {:error, :unexpected_body} = Company.fetch(nvidia())
    end

    test "an entity with no CIK is an error with no request" do
      stub_edgar()
      assert {:error, :no_cik} = Company.fetch(company("No Cik", nil))
      assert requests() == []
    end
  end

  describe "parse_facts/3" do
    @cik "0000000001"

    test "odd values become nil or empty, never a crash" do
      submissions = %{
        "name" => "Odd Inc",
        "tickers" => ["ODD", "", 5],
        "exchanges" => ["Nasdaq"],
        "sicDescription" => "",
        "category" => nil,
        "fiscalYearEnd" => "1301",
        "filings" => %{"recent" => %{"form" => ["8-K"]}}
      }

      assert {:ok, facts} =
               Company.parse_facts(submissions, %{"units" => %{"shares" => [%{}]}}, @cik)

      assert %{
               listings: [%{ticker: "ODD", exchange: "Nasdaq"}],
               industry: nil,
               category: nil,
               fiscal_year_end: nil,
               shares_outstanding: nil,
               filings: []
             } = facts
    end

    test "the shares value is the one with the latest period end" do
      shares = %{
        "units" => %{
          "shares" => [
            %{"end" => "2026-05-15", "val" => 2, "filed" => "2026-05-20"},
            %{"end" => "2026-08-21", "val" => 3, "filed" => "2026-08-26"},
            %{"end" => "2025-11-14", "val" => 1, "filed" => "2025-11-19"}
          ]
        }
      }

      assert {:ok, %{shares_outstanding: %{value: 3, as_of: "2026-08-21"}}} =
               Company.parse_facts(%{"name" => "X"}, shares, @cik)
    end

    test "fiscal year ends" do
      for {raw, expected} <- [
            {"0131", %{month: 1, day: 31}},
            {"1231", %{month: 12, day: 31}},
            {"0630", %{month: 6, day: 30}},
            {"", nil},
            {nil, nil},
            {"13", nil}
          ] do
        assert {:ok, %{fiscal_year_end: ^expected}} =
                 Company.parse_facts(%{"name" => "X", "fiscalYearEnd" => raw}, nil, @cik)
      end
    end

    test "a filing without an accession number or document is dropped" do
      recent = %{
        "form" => ["8-K", "8-K", "10-Q"],
        "filingDate" => ["2026-01-03", "2026-01-02", "2026-01-01"],
        "reportDate" => ["", "", ""],
        "items" => ["", "", ""],
        "accessionNumber" => ["", "0000000001-26-000002", "0000000001-26-000001"],
        "primaryDocument" => ["a.htm", "", "q.htm"],
        "primaryDocDescription" => ["", "", "10-Q"]
      }

      assert {:ok, %{filings: [filing]}} =
               Company.parse_facts(
                 %{"name" => "X", "filings" => %{"recent" => recent}},
                 nil,
                 "0000000001"
               )

      assert filing.url == "https://www.sec.gov/Archives/edgar/data/1/000000000126000001/q.htm"
      assert filing.description == "10-Q"
    end
  end

  defp with_edgar_config(config, fun) do
    previous = Application.fetch_env!(:knowseek, Knowseek.Cards.Edgar)
    Application.put_env(:knowseek, Knowseek.Cards.Edgar, Keyword.merge(previous, config))

    try do
      fun.()
    after
      Application.put_env(:knowseek, Knowseek.Cards.Edgar, previous)
    end
  end
end
