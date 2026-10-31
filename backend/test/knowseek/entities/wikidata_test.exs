defmodule Knowseek.Entities.WikidataTest do
  use ExUnit.Case, async: true

  import Knowseek.Fixtures

  alias Knowseek.Entities.{Entity, Wikidata}

  # The resolver runs in the test process, so private Req.Test stubs work.
  defp search(text), do: Wikidata.search(text, [])

  # Answers a search with `hits` and a details call with `items`.
  defp stub_api(hits, items) do
    Req.Test.stub(Wikidata, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.query_params["action"] do
        "wbsearchentities" ->
          Req.Test.json(conn, %{"success" => 1, "search" => hits})

        "wbgetentities" ->
          Req.Test.json(conn, %{"success" => 1, "entities" => items})
      end
    end)
  end

  defp item(attrs) do
    Map.merge(%{"id" => "Q1", "claims" => %{}, "sitelinks" => %{}}, attrs)
  end

  defp claim(property, value, extra \\ %{}) do
    Map.merge(
      %{
        "mainsnak" => %{"snaktype" => "value", "property" => property, "datavalue" => value},
        "rank" => "normal"
      },
      extra
    )
  end

  defp item_value(id), do: %{"type" => "wikibase-entityid", "value" => %{"id" => id}}

  defp ticker_qualifier(ticker) do
    %{
      "P249" => [
        %{"snaktype" => "value", "datavalue" => %{"type" => "string", "value" => ticker}}
      ]
    }
  end

  describe "search/2 with the recorded answers" do
    setup do
      stub_wikidata()
      :ok
    end

    test "knicks: candidates in search order, the Knicks first" do
      assert {:ok, [knicks | rest]} = search("knicks")

      assert %Entity{
               id: "Q131364",
               label: "New York Knicks",
               description: "National Basketball Association team in New York City",
               types: ["Q13393265"],
               sitelinks: 74,
               wikipedia_title: "New York Knicks",
               coordinates: nil,
               exchange_tickers: []
             } = knicks

      assert length(rest) == 19
      assert List.last(rest).id == "Q15927936"
      assert List.last(rest).label == "Westchester Knicks"
      assert List.last(rest).types == ["Q13393265"]
    end

    test "nvidia: the ticker comes from the P249 qualifier on the P414 exchange claim" do
      assert {:ok, [nvidia | _rest]} = search("nvidia")

      assert nvidia.id == "Q182477"
      assert nvidia.types == ["Q891723", "Q4830453"]
      assert nvidia.sitelinks == 82
      assert nvidia.exchange_tickers == [%{exchange: "Q82059", ticker: "NVDA"}]
    end

    test "apple: the ended Tokyo listing (P582 end time) is not listed" do
      assert {:ok, [apple | _rest]} = search("apple")

      assert apple.id == "Q312"
      # Q217475 (Tokyo Stock Exchange, ticker 6689) has a P582 end time of 2004
      # and rank normal. Wikidata still lists it on the item.
      assert apple.exchange_tickers == [%{exchange: "Q82059", ticker: "AAPL"}]
    end

    test "texas and japan: a state and a country have types and coordinates" do
      assert {:ok, [texas | _rest]} = search("texas")
      assert texas.id == "Q1439"
      assert texas.types == ["Q35657"]
      assert %{latitude: _, longitude: _} = texas.coordinates

      assert {:ok, [japan | _rest]} = search("japan")
      assert japan.id == "Q17"
      assert japan.types == ["Q3624078", "Q112099", "Q6256"]
      assert %{latitude: _, longitude: _} = japan.coordinates
    end

    test "nvda: the screen reader comes first and has no ticker or label" do
      assert {:ok, [screen_reader, nvidia | _rest]} = search("nvda")

      assert screen_reader.id == "Q1116614"
      assert screen_reader.label == "NonVisual Desktop Access"
      assert screen_reader.exchange_tickers == []
      assert "Q1328864" in screen_reader.types
      assert nvidia.id == "Q182477"
    end

    test "tokyo: coordinates from P625" do
      assert {:ok, [tokyo | _rest]} = search("tokyo")

      assert tokyo.id == "Q1490"
      assert tokyo.sitelinks == 303
      assert tokyo.wikipedia_title == "Tokyo"
      assert tokyo.coordinates == %{latitude: 35.68944444444445, longitude: 139.69166666666666}
      assert "Q1549591" in tokyo.types
    end

    test "an item with several exchanges lists them all" do
      assert {:ok, candidates} = search("tokyo")

      sony = Enum.find(candidates, &(&1.id == "Q41187"))

      assert sony.exchange_tickers == [
               %{exchange: "Q217475", ticker: "6758"},
               %{exchange: "Q13677", ticker: "SONY"}
             ]
    end

    test "sends two requests (search, then all details at once) with a User-Agent" do
      assert {:ok, [_ | _]} = search("knicks")

      assert_received {:wikidata_request, "wbsearchentities", params, [user_agent]}
      assert user_agent =~ "Knowseek"

      assert %{
               "search" => "knicks",
               "language" => "en",
               "type" => "item",
               "limit" => "20",
               "format" => "json",
               "maxlag" => "5"
             } = params

      assert_received {:wikidata_request, "wbgetentities", details, [^user_agent]}
      ids = String.split(details["ids"], "|")
      assert length(ids) == 20
      assert hd(ids) == "Q131364"
      assert details["props"] == "claims|sitelinks"

      refute_received {:wikidata_request, _, _, _}
    end

    test "no match is an empty list, without a details request" do
      assert search("weather in tokyo") == {:ok, []}

      assert_received {:wikidata_request, "wbsearchentities", _, _}
      refute_received {:wikidata_request, "wbgetentities", _, _}
    end
  end

  describe "search/2 claim parsing" do
    test "skips deprecated and ended exchange claims, and claims without a ticker" do
      stub_api([%{"id" => "Q1"}], %{
        "Q1" =>
          item(%{
            "claims" => %{
              "P414" => [
                claim("P414", item_value("Q10"), %{"qualifiers" => ticker_qualifier("OK")}),
                claim("P414", item_value("Q11"), %{
                  "rank" => "deprecated",
                  "qualifiers" => ticker_qualifier("BAD1")
                }),
                claim("P414", item_value("Q12"), %{
                  "qualifiers" => Map.put(ticker_qualifier("BAD2"), "P582", [%{}])
                }),
                claim("P414", item_value("Q13")),
                claim("P414", item_value("Q14"), %{"qualifiers" => ticker_qualifier("")})
              ]
            }
          })
      })

      assert {:ok, [entity]} = search("x")
      assert entity.exchange_tickers == [%{exchange: "Q10", ticker: "OK"}]
    end

    test "a claim with several tickers lists each" do
      qualifiers = %{
        "P249" =>
          for ticker <- ["AAA", "BBB"] do
            %{"snaktype" => "value", "datavalue" => %{"type" => "string", "value" => ticker}}
          end
      }

      stub_api([%{"id" => "Q1"}], %{
        "Q1" =>
          item(%{
            "claims" => %{
              "P414" => [claim("P414", item_value("Q10"), %{"qualifiers" => qualifiers})]
            }
          })
      })

      assert {:ok, [entity]} = search("x")

      assert entity.exchange_tickers == [
               %{exchange: "Q10", ticker: "AAA"},
               %{exchange: "Q10", ticker: "BBB"}
             ]
    end

    test "prefers the preferred coordinate and ignores deprecated ones and other globes" do
      earth = "http://www.wikidata.org/entity/Q2"

      point = fn lat, lon, globe ->
        %{
          "type" => "globecoordinate",
          "value" => %{"latitude" => lat, "longitude" => lon, "globe" => globe}
        }
      end

      stub_api([%{"id" => "Q1"}, %{"id" => "Q2"}, %{"id" => "Q3"}], %{
        "Q1" =>
          item(%{
            "id" => "Q1",
            "claims" => %{
              "P625" => [
                claim("P625", point.(1.0, 2.0, earth), %{"rank" => "deprecated"}),
                claim("P625", point.(3.0, 4.0, earth)),
                claim("P625", point.(5.0, 6.0, earth), %{"rank" => "preferred"})
              ]
            }
          }),
        "Q2" =>
          item(%{
            "id" => "Q2",
            "claims" => %{
              "P625" => [claim("P625", point.(7.0, 8.0, "http://www.wikidata.org/entity/Q111"))]
            }
          }),
        "Q3" =>
          item(%{
            "id" => "Q3",
            "claims" => %{
              "P625" => [claim("P625", point.(1.0, 2.0, earth), %{"rank" => "deprecated"})]
            }
          })
      })

      assert {:ok, [first, mars, deprecated]} = search("x")
      assert first.coordinates == %{latitude: 5.0, longitude: 6.0}
      assert mars.coordinates == nil
      assert deprecated.coordinates == nil
    end

    test "reads the English Wikipedia title and counts all sitelinks" do
      stub_api([%{"id" => "Q1"}], %{
        "Q1" =>
          item(%{
            "sitelinks" => %{
              "enwiki" => %{"site" => "enwiki", "title" => "Some Page"},
              "dewiki" => %{"site" => "dewiki", "title" => "Seite"}
            }
          })
      })

      assert {:ok, [entity]} = search("x")
      assert entity.sitelinks == 2
      assert entity.wikipedia_title == "Some Page"
    end

    test "an entity without claims or sitelinks has empty fields" do
      stub_api([%{"id" => "Q1", "label" => "Thing"}], %{"Q1" => %{"id" => "Q1"}})

      assert {:ok, [entity]} = search("x")

      assert entity == %Entity{
               id: "Q1",
               label: "Thing",
               description: nil,
               types: [],
               sitelinks: 0,
               wikipedia_title: nil,
               coordinates: nil,
               exchange_tickers: []
             }
    end

    test "drops a hit whose item is missing from the details answer" do
      stub_api([%{"id" => "Q1"}, %{"id" => "Q2"}], %{
        "Q1" => %{"id" => "Q1", "missing" => ""},
        "Q2" => item(%{"id" => "Q2"})
      })

      assert {:ok, [%Entity{id: "Q2"}]} = search("x")
    end
  end

  describe "search/2 failures" do
    test "an HTTP 429 is an error" do
      Req.Test.stub(Wikidata, &Plug.Conn.send_resp(&1, 429, "Too Many Requests"))

      assert search("knicks") == {:error, {:http_status, 429}}
    end

    test "a timeout is an error" do
      Req.Test.stub(Wikidata, &Req.Test.transport_error(&1, :timeout))

      assert {:error, %Req.TransportError{reason: :timeout}} = search("knicks")
    end

    test "an API error body is an error" do
      Req.Test.stub(Wikidata, &Req.Test.json(&1, %{"error" => %{"code" => "maxlag"}}))

      assert search("knicks") == {:error, {:api_error, "maxlag"}}
    end

    test "a body that is not a search answer is an error" do
      Req.Test.stub(Wikidata, &Req.Test.json(&1, %{"unexpected" => true}))

      assert search("knicks") == {:error, :unexpected_body}
    end

    test "a failing details request is an error" do
      Req.Test.stub(Wikidata, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        case conn.query_params["action"] do
          "wbsearchentities" -> Req.Test.json(conn, wikidata_fixture("search_knicks"))
          "wbgetentities" -> Plug.Conn.send_resp(conn, 503, "unavailable")
        end
      end)

      assert search("knicks") == {:error, {:http_status, 503}}
    end
  end
end
