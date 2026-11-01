defmodule Knowseek.Cards.Providers.TwelveDataCompany do
  @moduledoc """
  `Knowseek.Cards.Provider` for a public company's stock quote, from Twelve
  Data's `/quote` endpoint (`Knowseek.Cards.TwelveData`). Task 032, ADR 0021.

  ## Which entities

  An entity gets a card when all of these hold, decided with no network call:

    * `Knowseek.Entities.kind/1` is `:company`;
    * a Twelve Data API key is configured (`TWELVEDATA_API_KEY`). With no key
      the provider handles nothing and `Knowseek.Cards.get/2` is `:none`;
    * one of its `exchange_tickers` is on a supported exchange: Nasdaq
      (Wikidata `Q82059`) or the New York Stock Exchange (`Q13677`). Any other
      exchange is not handled (the symbol suffixes of other exchanges are not
      probed). A company listed on several supported exchanges uses the first
      one in the entity's `exchange_tickers` (Wikidata claim order).

  The request is `/quote?symbol=<ticker>&exchange=NASDAQ|NYSE`.

  ## The card

  `type: "company"`, `title` (the name Twelve Data gives, else the entity's
  label) and `facts`:

    * `source` - `"Twelve Data"`.
    * `symbol`, `exchange` (`"Nasdaq"` or `"NYSE"`), `currency`.
    * `price` - the last price; `previous_close`; `change` and
      `percent_change` (against the previous close; the percent is rounded to
      two decimals).
    * `market_state` - `"open"` or `"closed"`. Twelve Data gives only a
      boolean (`is_market_open`); its pre-market and after-hours quotes need a
      paid plan, so those two states are not reported, and "closed" includes
      the extended-hours sessions. The card is not wrong about the price: it
      is the last regular-session quote.
    * `quote_time` - the time of the quote itself (`last_quote_at`, UTC
      ISO 8601), or `nil`. It is when Twelve Data last updated the quote, not
      when we fetched it (the card's `as_of`).
    * `delayed` - `false`: Twelve Data documents `/quote` as real-time. The
      field exists so that a source that says "delayed" can say so, and the UI
      shows a delayed label when it is `true`.

  A body without a numeric price, or with a bad `previous_close`, is an error
  (the card goes stale or unavailable), never a card with `nil` prices.

  ## TTL

  `ttl/2`: open is 60 s (the free plan allows 8 requests a minute and 800 a
  day: more cards or a shorter TTL would run the daily limit out). Closed is
  until two minutes before the next regular open (Mon-Fri 09:30 America/New_York,
  holidays are not known), never more than an hour and never less than a
  minute.
  """
  @behaviour Knowseek.Cards.Provider

  alias Knowseek.Cards.TwelveData
  alias Knowseek.Entities
  alias Knowseek.Entities.Entity

  # Wikidata exchange id => {Twelve Data `exchange`, label}.
  @exchanges %{
    "Q82059" => {"NASDAQ", "Nasdaq"},
    "Q13677" => {"NYSE", "NYSE"}
  }

  @open_ttl :timer.seconds(60)
  @min_closed_ttl :timer.seconds(60)
  @closed_cap :timer.hours(1)
  @lead_ms :timer.minutes(2)

  @impl true
  def handles?(%Entity{} = entity) do
    TwelveData.api_key() != nil and Entities.kind(entity) == :company and
      listing(entity) != nil
  end

  @impl true
  def fetch(%Entity{} = entity) do
    case listing(entity) do
      nil -> {:error, :unsupported_exchange}
      {symbol, {exchange, _label}} -> fetch_quote(entity, symbol, exchange)
    end
  end

  defp fetch_quote(entity, symbol, exchange) do
    with {:ok, body} <- TwelveData.get("quote", symbol: symbol, exchange: exchange),
         {:ok, facts} <- parse(body, entity) do
      card = %{type: "company", title: title(body, entity), facts: facts}
      {:ok, card, ttl(facts, DateTime.utc_now())}
    end
  end

  defp title(%{"name" => name}, _entity) when is_binary(name) and name != "", do: name
  defp title(_body, entity), do: entity.label

  @doc """
  The `{symbol, {twelve_data_exchange, label}}` of the first supported listing
  of `entity`, or `nil`.
  """
  @spec listing(Entity.t()) :: {String.t(), {String.t(), String.t()}} | nil
  def listing(%Entity{exchange_tickers: tickers}) do
    Enum.find_value(tickers, fn %{exchange: exchange, ticker: ticker} ->
      with {:ok, mapped} <- Map.fetch(@exchanges, exchange),
           true <- is_binary(ticker) and ticker != "" do
        {ticker, mapped}
      else
        _unsupported -> nil
      end
    end)
  end

  ## Parsing (pure)

  @doc """
  The card facts from a Twelve Data `/quote` body for `entity`. See the module
  doc. `{:error, :malformed_quote}` when the price fields are not numbers.
  """
  @spec parse(map(), Entity.t()) :: {:ok, map()} | {:error, :malformed_quote}
  def parse(body, %Entity{} = entity) do
    {symbol, {_exchange, label}} = listing(entity) || {nil, {nil, nil}}

    with price when is_number(price) <- number(body["close"]),
         previous when is_number(previous) <- number(body["previous_close"]),
         open? when is_boolean(open?) <- body["is_market_open"] do
      change = number(body["change"]) || round_to(price - previous, 4)

      percent =
        case number(body["percent_change"]) do
          nil when previous != 0 -> change / previous * 100
          nil -> nil
          percent -> percent
        end

      {:ok,
       %{
         source: "Twelve Data",
         symbol: body["symbol"] || symbol,
         exchange: label,
         currency: body["currency"],
         price: price,
         previous_close: previous,
         change: change,
         percent_change: percent && round_to(percent, 2),
         market_state: if(open?, do: "open", else: "closed"),
         quote_time: quote_time(body),
         delayed: false
       }}
    else
      _bad -> {:error, :malformed_quote}
    end
  end

  defp number(value) when is_number(value), do: value

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _not_a_number -> nil
    end
  end

  defp number(_value), do: nil

  defp round_to(number, places), do: Float.round(number * 1.0, places)

  defp quote_time(body) do
    case body["last_quote_at"] || body["timestamp"] do
      seconds when is_integer(seconds) -> DateTime.from_unix!(seconds)
      _none -> nil
    end
  end

  ## TTL

  @doc """
  How long a card with these `facts` stays fresh at `now`, in milliseconds.
  See "TTL" in the module doc.
  """
  @spec ttl(map(), DateTime.t()) :: pos_integer()
  def ttl(%{market_state: "open"}, _now), do: @open_ttl

  def ttl(%{market_state: _closed}, now) do
    (DateTime.diff(next_open(now), now, :millisecond) - @lead_ms)
    |> min(@closed_cap)
    |> max(@min_closed_ttl)
  end

  @doc """
  The next regular session open (Monday to Friday, 09:30 in New York) after
  `now`, in UTC. Public holidays are not known: on one, the card refreshes at
  the open and finds the market closed again.
  """
  @spec next_open(DateTime.t()) :: DateTime.t()
  def next_open(%DateTime{} = now) do
    local = DateTime.add(now, eastern_offset(now))
    today = DateTime.to_date(local)

    first =
      if Time.compare(DateTime.to_time(local), ~T[09:30:00]) == :lt,
        do: today,
        else: Date.add(today, 1)

    date = Enum.find(Stream.iterate(first, &Date.add(&1, 1)), &(Date.day_of_week(&1) in 1..5))
    guess = DateTime.new!(date, ~T[09:30:00], "Etc/UTC")
    # The offset of that day, not of today: the clocks may change in between.
    DateTime.add(guess, -eastern_offset(DateTime.add(guess, 5 * 3600)))
  end

  # Seconds to add to UTC to get New York time. US daylight saving time: from
  # the second Sunday of March 02:00 local standard time (07:00 UTC) to the
  # first Sunday of November 02:00 local daylight time (06:00 UTC).
  defp eastern_offset(%DateTime{year: year} = utc) do
    dst_start = DateTime.new!(nth_sunday(year, 3, 2), ~T[07:00:00], "Etc/UTC")
    dst_end = DateTime.new!(nth_sunday(year, 11, 1), ~T[06:00:00], "Etc/UTC")

    if DateTime.compare(utc, dst_start) != :lt and DateTime.compare(utc, dst_end) == :lt,
      do: -4 * 3600,
      else: -5 * 3600
  end

  defp nth_sunday(year, month, n) do
    first = Date.new!(year, month, 1)
    days_to_sunday = rem(7 - Date.day_of_week(first), 7)
    Date.add(first, days_to_sunday + 7 * (n - 1))
  end
end
