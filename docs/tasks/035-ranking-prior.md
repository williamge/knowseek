# 035. Ranking prior from document importance

- Status: done
- Area: `Knowseek.Search`, `Knowseek.Documents`
- Depends on: none (page views were chosen, so 030 is not needed)

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

## Outcome

Decision and evidence: [ADR 0018](../decisions/0018-ranking-prior.md).

Built:

- Signal: Wikipedia page views per 30 days (not Wikidata sitelinks: on the
  ambiguous pairs probed, sitelinks ranked the fruit and the river above the
  company). The Wikipedia source reads it from the same API call as the text
  (`prop=pageviews`) and puts `:monthly_views` in the candidate.
- `documents.monthly_views` (nullable `bigint`, migration), written only by
  `Documents.ingest/1`. A candidate without a figure leaves the stored one.
- `Search` multiplies each document's score by
  `1 + prior_weight * min(1, log10(1 + views) / log10(1 + prior_saturation_views))`
  after grouping and sorts again. Defaults 0.3 and 1,000,000 in config, also
  options of `Search.search/2`. Documents without a figure rank and score as
  before. Formula and knobs are in `docs/ARCHITECTURE.md`.
- Tests: 81,520 against 6,276 views ranks the larger first (both insertion
  orders), no signal means unchanged ranking and scores, and a popular but
  clearly less relevant document stays below a relevant one (and wins only with
  an absurd weight).
- Smoke on the real path with `bge-m3`: for "new york knicks" Westchester
  Knicks was first before, and New York Knicks is first now.

Left out:

- A refresh job. The figure is taken at ingest and refreshed only when a
  document is re-ingested. No mechanism re-fetches an existing document today.
  How indexed documents are refreshed is undecided (on-demand re-fetch,
  scheduled, never); that is an open dependency of this feature. No Oban
  worker and no cron were added.
- The figure is not in the JSON API; `Hit.score` includes the prior.
- Signals for other sources (only Wikipedia has one).

Follow-ups (no task files written):

- Re-fetch policy for stored documents (decides how the figure stays current).
- Show the prior (or the views) in the UI or API if people need to see why a
  result ranks where it does.
- Wikidata sitelinks as a second signal once the entity context (task 030)
  exists, if page views prove too noisy for entities with no page.
