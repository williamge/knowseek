# 041. Card by entity id

- Status: open
- Area: `KnowseekWeb.CardController`, `Knowseek.Entities`, web (`useCard`, router, `FactCard`)
- Depends on: 033

## Goal

Let the reader pick another entity of the query, and get its card, even when it has the same label as the top one.

## Why

The "also:" chips re-search the label of an alternative (`weather in New York City`). An alternative with the same label as the top entity (Springfield, Illinois, Massachusetts and Missouri; Cambridge in England and in Massachusetts; Georgia the state and the country) cannot be reached that way: the endpoint drops it (`same_label?`), and a re-search would resolve the same top entity. Found in the review of [033](033-weather-card.md).

## Scope

- `GET /api/cards?q=<query>&entity=<Q-id>`: resolve the query as usual (cache-only), and if the id is one of the alternatives, make it the entity and the previous top one an alternative. An unknown id is ignored. No new upstream call: the candidates are in the entity cache.
- The route and `useCard` carry the chosen id (`/?q=...&entity=Q49111`); a new query clears it.
- Chips for same-label alternatives are kept for places, with the description as a visible disambiguation.

## Acceptance criteria

- A test with the recorded `cambridge` and `georgia` answers: asking for the second candidate returns its card.
- No change to the response for a query without `entity`.
- `make check-quiet` passes.
