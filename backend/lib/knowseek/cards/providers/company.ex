defmodule Knowseek.Cards.Providers.Company do
  @moduledoc """
  `Knowseek.Cards.Provider` for a public company: "what is this company", from
  the SEC's EDGAR (`Knowseek.Cards.Edgar`). Task 032, ADR 0021. No price: no
  keyless source of quotes allows automated use (ADR 0021).

  ## Which entities

  An entity gets a card when it is a company (`Knowseek.Entities.kind/1`, which
  needs a ticker on some exchange) and has an SEC Central Index Key (Wikidata
  P5531, `Entity.cik`). Any other entity is not handled (`none`). The SEC is
  asked for the key, so the exchange does not matter: an ADR filer on the NYSE
  and a company on an exchange abroad that files with the SEC get a card, and
  the tickers and exchanges on the card are the SEC's own. No network call
  decides this.

  ## The card

  `type: "company"`, `title` (the entity's label, else the SEC name) and `facts`:

    * `source`, `source_url` - `"SEC EDGAR"` and the company's EDGAR page: the
      credit the card shows.
    * `legal_name`, `cik`.
    * `listings` - `[%{ticker, exchange}]` from the submissions (`"NVDA"`,
      `"Nasdaq"`); empty when the SEC lists none.
    * `industry` (SIC description), `category` (filer category, for example
      `"Large accelerated filer"`), `fiscal_year_end` (`%{month, day}`); each can
      be `nil`.
    * `shares_outstanding` - `%{value, as_of}` from the cover page of the latest
      periodic report (`dei:EntityCommonStockSharesOutstanding`), or `nil`. A
      company with several share classes (Alphabet) has no such concept: the
      card is then without it. A 404 or any other failure of that one request
      is not a failure of the card.
    * `filings` - the five latest annual and periodic reports and current
      reports (10-K, 10-Q, 8-K, and 20-F, 40-F, 6-K for foreign filers), newest
      first: `form`, `filed` (date), `report_date` (or `nil`), `items`
      (8-K item numbers), `description` and `url` (the document on sec.gov).

  No revenue: the XBRL tag of the revenue differs per company and year.

  ## Requests and errors

  Two requests to `data.sec.gov`, in parallel: submissions and shares
  outstanding. `fetch/1` runs in the card cache's task, never in a request. A
  failed submissions request is an error (the card is `stale` or `unavailable`).
  HTTP 429 and HTTP 403 stop every fetch of this provider's cache (a 403 for ten
  minutes), and a 403 logs one warning that tells the operator to set
  `SEC_USER_AGENT` with a contact (the SEC blocks undeclared automated tools; see
  `Knowseek.Cards.Edgar`).

  ## TTL

  An hour: filings change rarely.
  """
  @behaviour Knowseek.Cards.Provider

  alias Knowseek.Cards.Edgar
  alias Knowseek.Entities
  alias Knowseek.Entities.Entity

  require Logger

  @ttl :timer.hours(1)
  # The SEC blocks an undeclared or too fast client for ten minutes.
  @forbidden_block_ms :timer.minutes(10)
  @forms ~w(10-K 10-Q 8-K 20-F 40-F 6-K)
  @max_filings 5
  @shares_concept "EntityCommonStockSharesOutstanding"

  @impl true
  def handles?(%Entity{} = entity) do
    Entities.kind(entity) == :company and is_binary(entity.cik)
  end

  @impl true
  def fetch(%Entity{cik: cik} = entity) when is_binary(cik) do
    submissions = Task.async(fn -> Edgar.submissions(cik) end)
    shares = Task.async(fn -> Edgar.dei_concept(cik, @shares_concept) end)
    results = {Task.await(submissions, :infinity), Task.await(shares, :infinity)}

    with {{:ok, submissions}, shares} <- results,
         {:ok, shares} <- shares_result(shares),
         {:ok, facts} <- parse_facts(submissions, shares, cik) do
      card = %{type: "company", title: entity.label || facts.legal_name, facts: facts}
      {:ok, card, @ttl}
    else
      {{:error, reason}, _shares} -> {:error, edgar_error(reason)}
      {:error, reason} -> {:error, edgar_error(reason)}
    end
  end

  def fetch(%Entity{}), do: {:error, :no_cik}

  # A company without the concept, or an odd answer for it, still has a card.
  # A rate limit or a block is not an odd answer.
  defp shares_result({:ok, body}), do: {:ok, body}
  defp shares_result({:error, :forbidden}), do: {:error, :forbidden}
  defp shares_result({:error, {:rate_limited, _ms}} = error), do: error
  defp shares_result({:error, _other}), do: {:ok, nil}

  defp edgar_error(:forbidden) do
    Logger.warning(
      "SEC EDGAR answered HTTP 403 (it blocks undeclared automated tools): company cards stop " <>
        "for #{div(@forbidden_block_ms, 60_000)} minutes. Set SEC_USER_AGENT to your name and a " <>
        "contact address, for example \"My Company admin@example.com\" " <>
        "(docs/decisions/0021-company-card-source.md)."
    )

    {:rate_limited, @forbidden_block_ms}
  end

  defp edgar_error(reason), do: reason

  @doc """
  The card facts (see the module doc) from a decoded `submissions/CIK<cik>.json`
  and the decoded shares-outstanding concept (`nil` when there is none).
  `{:error, :malformed_submissions}` when the submissions have no company name.
  """
  @spec parse_facts(map(), map() | nil, String.t()) :: {:ok, map()} | {:error, term()}
  def parse_facts(%{"name" => name} = submissions, shares, cik) when is_binary(name) do
    {:ok,
     %{
       source: "SEC EDGAR",
       source_url: "https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=#{cik}",
       legal_name: name,
       cik: cik,
       listings: listings(submissions["tickers"], submissions["exchanges"]),
       industry: text(submissions["sicDescription"]),
       category: text(submissions["category"]),
       fiscal_year_end: fiscal_year_end(submissions["fiscalYearEnd"]),
       shares_outstanding: shares_outstanding(shares),
       filings: filings(get_in(submissions, ["filings", "recent"]), cik)
     }}
  end

  def parse_facts(_submissions, _shares, _cik), do: {:error, :malformed_submissions}

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(_value), do: nil

  # `tickers` and `exchanges` are parallel lists; an exchange the SEC does not
  # give (a shorter list) is `nil`.
  defp listings(tickers, exchanges) when is_list(tickers) do
    exchanges = if is_list(exchanges), do: exchanges, else: []

    tickers
    |> Enum.with_index()
    |> Enum.flat_map(fn {ticker, index} ->
      if is_binary(ticker) and ticker != "",
        do: [%{ticker: ticker, exchange: text(Enum.at(exchanges, index))}],
        else: []
    end)
  end

  defp listings(_tickers, _exchanges), do: []

  # "0131" is January 31.
  defp fiscal_year_end(<<month::binary-size(2), day::binary-size(2)>>) do
    with {month, ""} when month in 1..12 <- Integer.parse(month),
         {day, ""} when day in 1..31 <- Integer.parse(day) do
      %{month: month, day: day}
    else
      _bad -> nil
    end
  end

  defp fiscal_year_end(_value), do: nil

  # The value with the latest period end (ties: the latest filing).
  defp shares_outstanding(%{"units" => %{"shares" => [_ | _] = values}}) do
    values
    |> Enum.filter(&(is_integer(&1["val"]) and is_binary(&1["end"])))
    |> Enum.max_by(&{&1["end"], &1["filed"] || ""}, fn -> nil end)
    |> case do
      nil -> nil
      latest -> %{value: latest["val"], as_of: latest["end"]}
    end
  end

  defp shares_outstanding(_concept), do: nil

  # `recent` holds parallel arrays, newest first.
  defp filings(%{} = recent, cik) do
    ~w(form filingDate reportDate items accessionNumber primaryDocument primaryDocDescription)
    |> Enum.map(&List.wrap(recent[&1]))
    |> Enum.zip()
    |> Stream.filter(fn {form, _filed, _report, _items, accession, document, _description} ->
      form in @forms and is_binary(accession) and accession != "" and is_binary(document) and
        document != ""
    end)
    |> Enum.take(@max_filings)
    |> Enum.map(fn {form, filed, report, items, accession, document, description} ->
      %{
        form: form,
        filed: filed,
        report_date: text(report),
        items: items_list(items),
        description: text(description),
        url:
          "https://www.sec.gov/Archives/edgar/data/#{String.to_integer(cik)}/" <>
            "#{String.replace(accession, "-", "")}/#{document}"
      }
    end)
  end

  defp filings(_recent, _cik), do: []

  defp items_list(items) when is_binary(items),
    do: items |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp items_list(_items), do: []
end
