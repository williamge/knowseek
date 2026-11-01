defmodule Knowseek.Cards.Providers.OpenMeteoTest do
  # The Open-Meteo stub runs in the same process here, but keep Req.Test shared like
  # the other provider tests.
  use ExUnit.Case, async: false

  import Knowseek.Fixtures
  import Req.Test, only: [set_req_test_from_context: 1]

  alias Knowseek.Cards.Providers.OpenMeteo
  alias Knowseek.Entities.{Entity, Wikidata}

  setup :set_req_test_from_context

  @big_city "Q1549591"

  defp place(attrs \\ []) do
    struct!(
      %Entity{
        id: "Q1490",
        label: "Tokyo",
        types: [@big_city],
        coordinates: %{latitude: 35.68944444444445, longitude: 139.69166666666666}
      },
      attrs
    )
  end

  describe "handles?/1 and intent/0" do
    test "a place with coordinates is handled, and only for the weather intent" do
      assert OpenMeteo.handles?(place())
      assert OpenMeteo.intent() == :weather
    end

    test "a place without coordinates, a team and a company are not handled" do
      refute OpenMeteo.handles?(place(coordinates: nil))
      refute OpenMeteo.handles?(place(types: ["Q13393265"]))
      refute OpenMeteo.handles?(place(types: ["Q4830453"]))
    end

    test "the recorded Tokyo and Texas are places" do
      stub_wikidata()

      for {query, label} <- [{"tokyo", "Tokyo"}, {"texas", "Texas"}] do
        assert {:ok, [entity | _]} = Wikidata.search(query, [])
        assert entity.label == label
        assert OpenMeteo.handles?(entity)
      end
    end
  end

  describe "fetch/1" do
    test "sends the entity's coordinates, the fields and a descriptive User-Agent" do
      stub_open_meteo()

      assert {:ok, _card, _ttl} = OpenMeteo.fetch(place())
      assert_received {:open_meteo_request, params, [user_agent]}

      assert params["latitude"] == "35.68944444444445"
      assert params["longitude"] == "139.69166666666666"
      assert params["timezone"] == "auto"
      assert params["forecast_days"] == "5"

      assert params["current"] ==
               "temperature_2m,apparent_temperature,relative_humidity_2m,precipitation," <>
                 "weather_code,wind_speed_10m,wind_direction_10m,is_day"

      assert params["daily"] ==
               "temperature_2m_max,temperature_2m_min,precipitation_probability_max," <>
                 "weather_code,sunrise,sunset"

      assert user_agent =~ "Knowseek/"
      assert user_agent =~ "github.com"
    end

    test "negative and whole-number coordinates are passed through" do
      stub_open_meteo()

      assert {:ok, _, _} = OpenMeteo.fetch(place(coordinates: %{latitude: 31, longitude: -100}))
      assert_received {:open_meteo_request, %{"latitude" => "31", "longitude" => "-100"}, _}
    end

    test "parses the recorded Tokyo forecast into a metric card" do
      stub_open_meteo()

      assert {:ok, %{type: "weather", title: "Tokyo", facts: facts}, ttl} =
               OpenMeteo.fetch(place())

      assert ttl == :timer.minutes(10)

      assert %{
               source: "Open-Meteo.com",
               source_url: "https://open-meteo.com/",
               timezone: "Asia/Tokyo",
               utc_offset_seconds: 32_400,
               observed_at: ~U[2026-11-01 01:00:00Z],
               current: %{
                 temperature_c: 17.0,
                 apparent_temperature_c: 15.7,
                 humidity_percent: 55,
                 precipitation_mm: precipitation,
                 wind_speed_kmh: 4.7,
                 wind_direction_deg: 351,
                 is_day: true,
                 weather_code: 0,
                 condition: "Clear sky",
                 icon: "☀️"
               },
               daily: [today | rest]
             } = facts

      assert precipitation == 0

      assert today == %{
               date: "2026-11-01",
               high_c: 19.9,
               low_c: 11.7,
               precipitation_probability_percent: 0,
               weather_code: 3,
               condition: "Overcast",
               icon: "☁️",
               sunrise: "2026-11-01T06:02",
               sunset: "2026-11-01T16:46"
             }

      assert length(rest) == 4
      assert Enum.map(rest, & &1.date) == ~w(2026-11-02 2026-11-03 2026-11-04 2026-11-05)

      assert Enum.map(rest, & &1.condition) == [
               "Drizzle",
               "Light drizzle",
               "Light drizzle",
               "Rain showers"
             ]
    end

    test "the card is JSON-encodable" do
      stub_open_meteo()
      assert {:ok, card, _ttl} = OpenMeteo.fetch(place())
      assert {:ok, json} = Jason.encode(card)
      assert json =~ "\"observed_at\":\"2026-11-01T01:00:00Z\""
    end

    test "an entity with no coordinates is an error, with no request" do
      stub_open_meteo()
      assert {:error, :no_coordinates} = OpenMeteo.fetch(place(coordinates: nil))
      refute_received {:open_meteo_request, _, _}
    end

    test "HTTP 429 is a rate limit with Retry-After" do
      stub_open_meteo(fn conn ->
        conn |> Plug.Conn.put_resp_header("retry-after", "30") |> Plug.Conn.send_resp(429, "")
      end)

      assert {:error, {:rate_limited, 30_000}} = OpenMeteo.fetch(place())
    end

    test "HTTP 429 without Retry-After waits a minute" do
      stub_open_meteo(&Plug.Conn.send_resp(&1, 429, ""))
      assert {:error, {:rate_limited, 60_000}} = OpenMeteo.fetch(place())
    end

    test "another HTTP error is an error" do
      stub_open_meteo(&Plug.Conn.send_resp(&1, 500, ""))
      assert {:error, {:http_status, 500}} = OpenMeteo.fetch(place())
    end

    test "a transport error is an error" do
      stub_open_meteo(&Req.Test.transport_error(&1, :econnrefused))
      assert {:error, %Req.TransportError{reason: :econnrefused}} = OpenMeteo.fetch(place())
    end

    test "a body that is not a JSON object is an error" do
      stub_open_meteo(&Req.Test.json(&1, ["no"]))
      assert {:error, :unexpected_body} = OpenMeteo.fetch(place())
    end

    test "an answer without current conditions is malformed" do
      body = Map.delete(open_meteo_fixture("forecast_tokyo"), "current")
      stub_open_meteo(body)
      assert {:error, :malformed} = OpenMeteo.fetch(place())
    end

    test "Open-Meteo's own error answer (HTTP 400) is an error" do
      stub_open_meteo(fn conn ->
        conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => true, "reason" => "bad"})
      end)

      assert {:error, {:http_status, 400}} = OpenMeteo.fetch(place())
    end
  end

  describe "parse/1" do
    defp body, do: open_meteo_fixture("forecast_tokyo")

    test "missing numbers are nil, not a crash" do
      body = put_in(body()["current"], %{"time" => "2026-11-01T10:00", "weather_code" => 61})

      assert {:ok, %{current: current}} = OpenMeteo.parse(body)
      assert current.temperature_c == nil
      assert current.wind_speed_kmh == nil
      assert current.weather_code == 61
      assert current.condition == "Light rain"
      # No is_day: counts as day.
      assert current.is_day
    end

    test "night uses the night icon" do
      body = put_in(body()["current"]["is_day"], 0)
      assert {:ok, %{current: %{is_day: false, icon: "🌙"}}} = OpenMeteo.parse(body)
    end

    test "daily lists of uneven length give nil for what is missing" do
      body = put_in(body()["daily"]["temperature_2m_max"], [20.0])
      assert {:ok, %{daily: [first, second | _]}} = OpenMeteo.parse(body)
      assert first.high_c == 20.0
      assert second.high_c == nil
    end

    test "no daily block is an empty forecast" do
      assert {:ok, %{daily: []}} = OpenMeteo.parse(Map.delete(body(), "daily"))
    end

    test "the local time is converted to UTC with the offset (a negative one too)" do
      body =
        body()
        |> Map.put("utc_offset_seconds", -18_000)
        |> put_in(["current", "time"], "2026-11-01T10:15")

      assert {:ok, %{observed_at: ~U[2026-11-01 15:15:00Z], utc_offset_seconds: -18_000}} =
               OpenMeteo.parse(body)
    end

    test "a time that is no ISO time, no offset or no time zone is malformed" do
      assert {:error, :malformed} = OpenMeteo.parse(put_in(body()["current"]["time"], "noon"))
      assert {:error, :malformed} = OpenMeteo.parse(put_in(body()["current"]["time"], 5))
      assert {:error, :malformed} = OpenMeteo.parse(Map.delete(body(), "utc_offset_seconds"))
      assert {:error, :malformed} = OpenMeteo.parse(Map.delete(body(), "timezone"))
      assert {:error, :malformed} = OpenMeteo.parse(%{})
    end
  end

  describe "weather codes" do
    @wmo [0, 1, 2, 3, 45, 48, 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 71, 73, 75, 77] ++
           [80, 81, 82, 85, 86, 95, 96, 99]

    test "the table has every WMO code Open-Meteo returns" do
      assert OpenMeteo.codes() == @wmo
    end

    for code <- @wmo do
      test "code #{code} has a text and a day and a night icon" do
        text = OpenMeteo.condition(unquote(code))
        refute text in ["", "Unknown"]
        assert OpenMeteo.icon(unquote(code), true) != "🌡️"
        assert OpenMeteo.icon(unquote(code), false) != "🌡️"
      end
    end

    test "texts are distinct" do
      texts = Enum.map(@wmo, &OpenMeteo.condition/1)
      assert texts == Enum.uniq(texts)
    end

    test "an unknown code is Unknown with a neutral icon" do
      assert OpenMeteo.condition(42) == "Unknown"
      assert OpenMeteo.condition(nil) == "Unknown"
      assert OpenMeteo.icon(42, true) == "🌡️"
    end
  end

  describe "ttl/1" do
    test "two thirds of the update interval: 10 minutes for 900 s" do
      assert OpenMeteo.ttl(900) == :timer.minutes(10)
    end

    test "never under 5 or over 15 minutes" do
      assert OpenMeteo.ttl(60) == :timer.minutes(5)
      assert OpenMeteo.ttl(10_000) == :timer.minutes(15)
    end

    test "a missing, zero or odd interval counts as 900 s" do
      for odd <- [nil, 0, -5, "900", 900.0] do
        assert OpenMeteo.ttl(odd) == :timer.minutes(10)
      end
    end
  end
end
