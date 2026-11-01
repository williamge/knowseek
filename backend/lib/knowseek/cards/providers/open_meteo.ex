defmodule Knowseek.Cards.Providers.OpenMeteo do
  @moduledoc """
  `Knowseek.Cards.Provider` for the weather of a place, from Open-Meteo's forecast API
  (`Knowseek.Cards.OpenMeteo`). Task 033, ADR 0022.

  ## Which queries

  An entity gets a card when it is a place (`Knowseek.Entities.kind/1`: a Wikidata item of
  a supported place type with coordinates) **and the query asked for weather**
  (`intent/0` is `:weather`: `weather in tokyo`, `tokyo weather`). `tokyo` alone is a
  search, not a weather question, so it has no card. A team with the weather intent
  (`knicks weather`) is not a place: it keeps the team card (ADR 0022).

  The forecast is for the entity's Wikidata coordinates (P625). For a state or a country
  that is one point, not the whole area.

  ## The card

  `type: "weather"`, `title` (the entity label) and `facts`. Values are metric; the web
  UI converts them to the reader's units.

    * `source`, `source_url` - `"Open-Meteo.com"` and its URL: the credit that CC BY 4.0
      requires, which the card shows.
    * `timezone` (IANA, for example `"Asia/Tokyo"`), `utc_offset_seconds`.
    * `observed_at` - when the current conditions are from (UTC).
    * `current` - `temperature_c`, `apparent_temperature_c`, `humidity_percent`,
      `precipitation_mm`, `wind_speed_kmh`, `wind_direction_deg`, `is_day`, `weather_code`,
      `condition` (short text) and `icon` (an emoji); a number the answer lacks is `nil`.
    * `daily` - today and the next days (`@forecast_days`): `date` (the place's local
      date), `high_c`, `low_c`, `precipitation_probability_percent`, `weather_code`,
      `condition`, `icon`, `sunrise`, `sunset` (the place's local time, without offset).

  The WMO weather code to text and icon table is in this module (`condition/1`, `icon/2`);
  the web UI shows what the card says.

  ## TTL

  Open-Meteo updates `current` every 15 minutes (`current.interval`, 900 s). The card
  stays fresh for two thirds of that interval (10 minutes), never less than 5 or more
  than 15 minutes (`ttl/1`).
  """
  @behaviour Knowseek.Cards.Provider

  alias Knowseek.Cards.OpenMeteo
  alias Knowseek.Entities
  alias Knowseek.Entities.Entity

  @forecast_days 5
  @default_interval_s 900
  @min_ttl :timer.minutes(5)
  @max_ttl :timer.minutes(15)

  @current ~w(temperature_2m apparent_temperature relative_humidity_2m precipitation
              weather_code wind_speed_10m wind_direction_10m is_day)
  @daily ~w(temperature_2m_max temperature_2m_min precipitation_probability_max
            weather_code sunrise sunset)

  # WMO weather interpretation codes, as Open-Meteo returns them: text, day icon, night icon.
  @codes %{
    0 => {"Clear sky", "☀️", "🌙"},
    1 => {"Mainly clear", "🌤️", "🌙"},
    2 => {"Partly cloudy", "⛅", "☁️"},
    3 => {"Overcast", "☁️", "☁️"},
    45 => {"Fog", "🌫️", "🌫️"},
    48 => {"Freezing fog", "🌫️", "🌫️"},
    51 => {"Light drizzle", "🌦️", "🌧️"},
    53 => {"Drizzle", "🌦️", "🌧️"},
    55 => {"Heavy drizzle", "🌧️", "🌧️"},
    56 => {"Light freezing drizzle", "🌧️", "🌧️"},
    57 => {"Freezing drizzle", "🌧️", "🌧️"},
    61 => {"Light rain", "🌦️", "🌧️"},
    63 => {"Rain", "🌧️", "🌧️"},
    65 => {"Heavy rain", "🌧️", "🌧️"},
    66 => {"Light freezing rain", "🌧️", "🌧️"},
    67 => {"Freezing rain", "🌧️", "🌧️"},
    71 => {"Light snow", "🌨️", "🌨️"},
    73 => {"Snow", "🌨️", "🌨️"},
    75 => {"Heavy snow", "❄️", "❄️"},
    77 => {"Snow grains", "🌨️", "🌨️"},
    80 => {"Light rain showers", "🌦️", "🌧️"},
    81 => {"Rain showers", "🌧️", "🌧️"},
    82 => {"Violent rain showers", "🌧️", "🌧️"},
    85 => {"Light snow showers", "🌨️", "🌨️"},
    86 => {"Heavy snow showers", "❄️", "❄️"},
    95 => {"Thunderstorm", "⛈️", "⛈️"},
    96 => {"Thunderstorm with hail", "⛈️", "⛈️"},
    99 => {"Thunderstorm with heavy hail", "⛈️", "⛈️"}
  }

  @impl true
  def handles?(%Entity{} = entity), do: Entities.kind(entity) == :place

  @impl true
  def intent, do: :weather

  @impl true
  def fetch(%Entity{coordinates: %{latitude: latitude, longitude: longitude}} = entity) do
    params = [
      latitude: latitude,
      longitude: longitude,
      current: Enum.join(@current, ","),
      daily: Enum.join(@daily, ","),
      timezone: "auto",
      forecast_days: @forecast_days
    ]

    with {:ok, body} <- OpenMeteo.get(params),
         {:ok, facts} <- parse(body) do
      {:ok, %{type: "weather", title: entity.label, facts: facts},
       ttl(get_in(body, ["current", "interval"]))}
    end
  end

  def fetch(%Entity{}), do: {:error, :no_coordinates}

  ## Parsing (pure)

  @doc """
  The card facts from an Open-Meteo forecast body, or `{:error, :malformed}` when it has
  no current conditions or no time zone. See the module doc for the shape.
  """
  @spec parse(map()) :: {:ok, map()} | {:error, :malformed}
  def parse(%{"current" => %{"time" => time} = current, "timezone" => timezone} = body)
      when is_binary(timezone) do
    offset = integer(body["utc_offset_seconds"])

    with offset when is_integer(offset) <- offset,
         {:ok, observed_at} <- local_to_utc(time, offset) do
      is_day = current["is_day"] != 0
      code = integer(current["weather_code"])

      {:ok,
       %{
         source: "Open-Meteo.com",
         source_url: "https://open-meteo.com/",
         timezone: timezone,
         utc_offset_seconds: offset,
         observed_at: observed_at,
         current: %{
           temperature_c: number(current["temperature_2m"]),
           apparent_temperature_c: number(current["apparent_temperature"]),
           humidity_percent: number(current["relative_humidity_2m"]),
           precipitation_mm: number(current["precipitation"]),
           wind_speed_kmh: number(current["wind_speed_10m"]),
           wind_direction_deg: number(current["wind_direction_10m"]),
           is_day: is_day,
           weather_code: code,
           condition: condition(code),
           icon: icon(code, is_day)
         },
         daily: daily(body["daily"])
       }}
    else
      _bad -> {:error, :malformed}
    end
  end

  def parse(_body), do: {:error, :malformed}

  defp daily(%{"time" => dates} = daily) when is_list(dates) do
    dates
    |> Enum.with_index()
    |> Enum.filter(fn {date, _index} -> is_binary(date) end)
    |> Enum.map(fn {date, index} ->
      at = fn key -> daily |> Map.get(key) |> at(index) end
      code = integer(at.("weather_code"))

      %{
        date: date,
        high_c: number(at.("temperature_2m_max")),
        low_c: number(at.("temperature_2m_min")),
        precipitation_probability_percent: number(at.("precipitation_probability_max")),
        weather_code: code,
        condition: condition(code),
        icon: icon(code, true),
        sunrise: text(at.("sunrise")),
        sunset: text(at.("sunset"))
      }
    end)
  end

  defp daily(_none), do: []

  defp at(list, index) when is_list(list), do: Enum.at(list, index)
  defp at(_not_a_list, _index), do: nil

  # Open-Meteo local times have no seconds or offset: `2026-11-01T10:00`.
  defp local_to_utc(time, offset) when is_binary(time) do
    time = if time =~ ~r/T\d\d:\d\d\z/, do: time <> ":00", else: time

    case NaiveDateTime.from_iso8601(time) do
      {:ok, naive} ->
        {:ok, naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.add(-offset, :second)}

      {:error, _reason} ->
        :error
    end
  end

  defp local_to_utc(_time, _offset), do: :error

  defp number(value) when is_number(value), do: value
  defp number(_value), do: nil

  defp integer(value) when is_integer(value), do: value
  defp integer(value) when is_float(value), do: trunc(value)
  defp integer(_value), do: nil

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: nil

  ## Weather codes

  @doc "The WMO weather codes the card has a text for."
  @spec codes() :: [non_neg_integer()]
  def codes, do: @codes |> Map.keys() |> Enum.sort()

  @doc "Short text for a WMO weather `code`; `\"Unknown\"` for a code not in the table."
  @spec condition(integer() | nil) :: String.t()
  def condition(code) do
    case Map.fetch(@codes, code) do
      {:ok, {text, _day, _night}} -> text
      :error -> "Unknown"
    end
  end

  @doc "An emoji for a WMO weather `code` by day or night; a thermometer for an unknown code."
  @spec icon(integer() | nil, boolean()) :: String.t()
  def icon(code, day?) do
    case Map.fetch(@codes, code) do
      {:ok, {_text, day, night}} -> if day?, do: day, else: night
      :error -> "🌡️"
    end
  end

  ## TTL

  @doc """
  How long a card stays fresh, in milliseconds, from Open-Meteo's update interval in
  seconds (`current.interval`): two thirds of it, between 5 and 15 minutes. A missing or
  odd interval counts as 900 s.
  """
  @spec ttl(term()) :: pos_integer()
  def ttl(interval) when is_integer(interval) and interval > 0 do
    (interval * 1000 * 2) |> div(3) |> max(@min_ttl) |> min(@max_ttl)
  end

  def ttl(_interval), do: ttl(@default_interval_s)
end
