defmodule Knowseek.Entities.Entity do
  @moduledoc """
  A thing a query is about, as a card provider needs it. Built by a
  `Knowseek.Entities.Resolver`; the ids are Wikidata's for the Wikidata
  resolver.

    * `id` - Q-id, for example `"Q131364"`.
    * `label`, `description` - English; either can be `nil`.
    * `types` - `instance of` (P31) ids.
    * `sitelinks` - how many wiki pages link the item. A proxy for how
      well known it is.
    * `wikipedia_title` - the English Wikipedia page title, or `nil`.
    * `coordinates` - `%{latitude: float, longitude: float}` from P625 (a
      place on Earth), or `nil`.
    * `exchange_tickers` - one `%{exchange: "Q82059", ticker: "NVDA"}` per
      stock exchange claim (P414) with a ticker symbol qualifier (P249).
      `exchange` is the Wikidata id of the exchange. Empty for most items.
    * `leagues` - ids of the leagues a sports team plays in now (P118,
      without deprecated claims and claims with an end time), for example
      `["Q155223"]` for the NBA. Empty for most items.
  """

  defstruct id: nil,
            label: nil,
            description: nil,
            types: [],
            sitelinks: 0,
            wikipedia_title: nil,
            coordinates: nil,
            exchange_tickers: [],
            leagues: []

  @type coordinates :: %{latitude: float(), longitude: float()}
  @type exchange_ticker :: %{exchange: String.t(), ticker: String.t()}

  @type t :: %__MODULE__{
          id: String.t(),
          label: String.t() | nil,
          description: String.t() | nil,
          types: [String.t()],
          sitelinks: non_neg_integer(),
          wikipedia_title: String.t() | nil,
          coordinates: coordinates() | nil,
          exchange_tickers: [exchange_ticker()],
          leagues: [String.t()]
        }
end
