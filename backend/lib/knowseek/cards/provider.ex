defmodule Knowseek.Cards.Provider do
  @moduledoc """
  Behaviour for a source of live facts about one kind of entity: ESPN for
  NBA teams now, SEC EDGAR and Open-Meteo later (tasks 032 and 033).

  A provider is read-only: it calls its upstream and returns a card. It never
  writes to the database and never caches (`Knowseek.Cards` does, with
  `Knowseek.Cache`, and calls `fetch/1` in a supervised task, never in a
  request). Register providers in config, in the order they are tried:

      config :knowseek, Knowseek.Cards, providers: [MyProvider]

  A card is a map with:

    * `type` - what the UI renders, for example `"sports_team"`.
    * `title` - the heading.
    * `facts` - a map of JSON-encodable facts, whose shape belongs to `type`.
  """

  alias Knowseek.Entities.Entity

  @type card :: %{type: String.t(), title: String.t(), facts: map()}

  @doc """
  True when this provider makes cards for `entity`. Decided from the entity
  alone, with no network call.
  """
  @callback handles?(Entity.t()) :: boolean()

  @doc """
  Fetches the card and how long it stays fresh, in milliseconds (a live game
  and a finished game need different TTLs). An error is any term; a rate limit
  is `{:rate_limited, retry_after_ms}` (see `Knowseek.Cache.rate_limited/1`).
  """
  @callback fetch(Entity.t()) :: {:ok, card(), ttl_ms :: non_neg_integer()} | {:error, term()}
end
