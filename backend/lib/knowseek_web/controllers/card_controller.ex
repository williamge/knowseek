defmodule KnowseekWeb.CardController do
  @moduledoc """
  `GET /api/cards?q=<query>`: the live fact card for what the query is about.

  Cache-only (rule 6): resolving the entity (`Knowseek.Entities`) and reading
  its card (`Knowseek.Cards`) read in-memory caches and start background
  refreshes; nothing here calls Wikidata or a card provider. The client polls
  until the status is not `pending`, and again after `refresh_after_ms`.

  Statuses: `pending` (the entity or the card is not cached yet), `fresh`,
  `stale` (cached data past its TTL: a refresh runs or failed), `unavailable`
  (a source failed and nothing is cached), `none` (the query names no entity
  with a card; the UI shows nothing).

  Tests pass options to the two contexts with
  `Application.put_env(:knowseek, KnowseekWeb.CardController, entities: [...], cards: [...])`.
  """
  use KnowseekWeb, :controller

  alias Knowseek.{Cards, Entities}

  action_fallback KnowseekWeb.FallbackController

  # Anonymous input starts Wikidata lookups: limited per client (ADR 0023).
  plug KnowseekWeb.Plugs.RateLimit, bucket: :cards

  # A query longer than this is no entity name; it is not even parsed.
  @max_query_bytes 1_000
  @pending_poll_ms 700
  @unavailable_poll_ms 30_000
  @none_poll_ms 60_000

  def show(conn, %{"q" => q}) when is_binary(q) do
    case String.trim(q) do
      "" -> {:error, {:bad_request, "q is required"}}
      query -> render(conn, :show, card: card(query))
    end
  end

  def show(_conn, _params), do: {:error, {:bad_request, "q is required"}}

  defp card(query) when byte_size(query) > @max_query_bytes, do: none()

  defp card(query) do
    options = Application.get_env(:knowseek, __MODULE__, [])

    case Entities.resolve(query, Keyword.get(options, :entities, [])) do
      {:ok, %{entity: entity, alternatives: alternatives}} ->
        entity_card(entity, alternatives, Keyword.get(options, :cards, []))

      {:pending, _query} ->
        base(:pending, @pending_poll_ms)

      :none ->
        none()

      {:error, _reason} ->
        base(:unavailable, @unavailable_poll_ms)
    end
  end

  defp entity_card(entity, alternatives, card_options) do
    case Cards.get(entity, card_options) do
      :none ->
        none()

      card ->
        %{
          base(card.status, card.refresh_after_ms)
          | entity: entity,
            alternatives: Enum.reject(alternatives, &same_label?(&1, entity)),
            card: card.type && Map.take(card, [:type, :title, :facts]),
            as_of: card.as_of
        }
    end
  end

  # Wikidata can have two items with one label (the Denver Nuggets of the NBA
  # and of the old NBL): "also: Denver Nuggets" under "Denver Nuggets" helps no one.
  defp same_label?(%{label: label}, %{label: top}) when is_binary(label) and is_binary(top),
    do: String.downcase(String.trim(label)) == String.downcase(String.trim(top))

  defp same_label?(_alternative, _entity), do: false

  defp none, do: base(:none, @none_poll_ms)

  defp base(status, refresh_after_ms) do
    %{
      status: status,
      entity: nil,
      alternatives: [],
      card: nil,
      as_of: nil,
      refresh_after_ms: refresh_after_ms
    }
  end
end
