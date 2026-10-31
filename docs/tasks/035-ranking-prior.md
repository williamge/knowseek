# 035. Ranking prior from document importance

- Status: open
- Area: `Knowseek.Search`, `Knowseek.Documents`
- Depends on: none (030 only if the prior uses Wikidata sitelinks)

The owner has not decided the priority of this task. It is a proposal from the
live-facts design session ([028](028-live-facts-for-entities.md), [ADR
0017](../decisions/0017-live-fact-cards.md)).

## Goal

Rank more important documents higher when relevance is otherwise similar, so
"knicks" puts New York Knicks above Westchester Knicks.

## Context

`Knowseek.Search` runs a keyword list and a vector list over chunks, fuses them
with reciprocal rank fusion (`@rrf_k 60` in `backend/lib/knowseek/search.ex`),
then groups by document. A document's score is its best chunk's score. Nothing
about the document counts: not how widely read it is, not how central the
entity is.

Numbers from October: Wikipedia pageviews New York Knicks 81,520 against
Westchester Knicks 6,276. The Wikidata item Q131364 has 74 sitelinks.

## Scope

- Choose a signal: Wikipedia pageviews (a monthly figure from the pageviews
  API) or Wikidata sitelink count. Record the choice and why in an ADR.
- Store it on the document (a schema change: migration, and writes through
  `Knowseek.Documents`, rule 2). Pageviews need a refresh job (Oban, rule 6).
- Apply it as a bounded prior to the document score, for example a damped
  `log` of the signal added after fusion, so relevance still dominates.
- Document the formula and its config knobs in `docs/ARCHITECTURE.md`.

## Acceptance criteria

- Regression test: two documents with equal chunk relevance and pageview signals
  81,520 and 6,276 rank the larger first; a clearly less relevant but popular
  document does not outrank a clearly relevant one.
- Documents without a signal rank as before.
- `make check-quiet` passes.

## Out of scope

Recency, passage selection, the entity card.
