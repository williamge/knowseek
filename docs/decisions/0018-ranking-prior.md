# 0018. A ranking prior from Wikipedia page views

- Status: Accepted
- Date: 2026-10-31

Related: task [035](../tasks/035-ranking-prior.md),
[ADR 0017](0017-live-fact-cards.md) (proposed the prior),
[ADR 0011](0011-one-hit-per-document.md) (document grouping).

## Context

`Knowseek.Search` fuses a full-text list and a vector list of chunks with
reciprocal rank fusion (RRF), then groups by document: a document's score is its
best chunk's score. Nothing about the document counts, so for "knicks" the
widely read article and a minor same-name article compete on text alone. The
task asks for a bounded prior from document importance that breaks near-ties.

## Evidence

All numbers were fetched on 2026-10-30/31 with a descriptive `User-Agent`.
"Views" are English Wikipedia, all-access, user agents, monthly, from the
Wikimedia REST pageviews API (Aug / Sep / Oct 2026). "Sitelinks" are the number
of language editions on the article's Wikidata item (`wbgetentities`,
`props=sitelinks`).

| Pair (the thing people mean first) | Views Oct | Sitelinks | Reading |
| --- | ---: | ---: | --- |
| New_York_Knicks / Westchester_Knicks | 81,520 / 6,276 | 74 / 16 | Both signals separate them (13x views, 4.6x sitelinks). |
| Apple_Inc. / Apple (fruit) | 160,914 / 71,788 | 184 / 242 | Views rank the company first. Sitelinks rank the fruit first. |
| Amazon_(company) / Amazon_River | 249,758 / 34,130 | 124 / 218 | Views separate by 7x. Sitelinks point the other way. |
| Mercury_(planet) / Mercury_(element) | 66,878 / 45,561 | 274 / 186 | Both agree; a mild preference. |
| Jaguar_Cars / Jaguar (animal) | 44,816 / 75,807 | 69 / 131 | Both prefer the animal. |
| Python_(programming_language) / Python_(genus) | 158,705 / 4,995 | 164 / 67 | Both agree; views by 32x. |
| Java (island) / Java_(programming_language) | 34,868 / 37,070 | 170 / 159 | Neither separates them. Honestly ambiguous. |

Views vary by tens of percent from month to month for stable subjects (Apple
Inc.: 181k, 301k, 161k in Aug, Sep, Oct) and more for a team in season. A log
damps all of it. Sitelinks barely change, but they measure how encyclopedic a
subject is, not what people look for: they favour geography and science
(Amazon River, the fruit) over companies and sports teams. Where one reading
is clearly "the thing people mean" (the company, not the river or the fruit),
sitelinks point the other way in two of the five ambiguous pairs above, and
views never do. Views cannot separate every pair either (Java), and then the
prior is small by design.

Current ranking, with the real path: `POST /api/search` with "knicks" enqueued
discovery, which indexed *New York Knicks*, *Westchester Knicks* and *2025-26
New York Knicks season* from the real Wikipedia API. The ranking before this
change is `Search.search/2` with `prior_weight: 0` (the same code path as
before). With the real `bge-m3` embeddings the order for "knicks" was New
York Knicks (0.0320), Westchester Knicks (0.0307), season (0.0290). For "new
york knicks" the order was **Westchester Knicks (0.0323)** above New York
Knicks (0.0318): the minor article won on text. That near-tie is what the
prior breaks. With the prior the "knicks" order is unchanged but the lead
grows (0.0398 against 0.0364), and "new york knicks" puts New York Knicks
first (0.0395 against 0.0382). "westchester knicks" still puts Westchester
first (0.0385 against 0.0191): relevance dominates.

Candidate pageviews came from the same request as the article text. MediaWiki's
`prop=pageviews` (PageViewInfo) returns up to 60 daily figures per page, and
the source already requests one page at a time with `prop=extracts|info|...`,
so adding it costs no extra HTTP call. Its 60-day average scaled to 30 days
gave New York Knicks 71,666 and Westchester Knicks 5,006 on 2026-10-31 (13x in
the REST API's October figures, 14x here).

## Decision

### Signal: monthly Wikipedia page views

- Page views, not Wikidata sitelinks. They follow what readers look for, they
  separate the ambiguous pairs that matter (companies, teams, languages) and
  they need no second service. Sitelinks would need a Wikidata call per
  candidate and, per task 035, a dependency on task 030.
- The unit is **views per 30 days**: the mean of the days that have data in
  the last 60 (today's value is always `null`), times 30, rounded.
- Obtained at ingest time, from the same API call as the text. The Wikipedia
  source puts it in the candidate as `:monthly_views`, and leaves the key out
  when the API has no figure.

### Where it lives

- A nullable `bigint` column `documents.monthly_views`, written only by
  `Documents.ingest/1` (rule 2). A source only finds the number (rule 3).
- Re-ingesting a document at its own URL updates the figure, whether or not the
  body changed. A candidate without the key leaves the stored value alone,
  so a lookup that failed this time does not erase an earlier figure.
  A document that is only touched because its body is a copy of another
  document's (ADR 0013) keeps its own figure.
- Documents from sources without such a figure (manual ingest) have `NULL`.

### Refresh: none, and that is a named open dependency

The figure changes monthly. It is taken at ingest and refreshed **only when the
document is re-ingested**, which today means when a discovery run finds the
page again. **No mechanism re-fetches an existing document.** Nothing runs on a
schedule (ADR 0015 removed the cron), and an on-demand re-fetch does not exist.
The owner has not decided how indexed documents are kept current (on-demand
re-fetch, a schedule, or never). So this ADR adds **no Oban worker, no cron
and no re-fetch**: a figure on a stored document can be arbitrarily old.
The cost of the staleness is bounded: the prior is a log, capped at +30%, so
an old figure that is off by 2x moves the score by about 1.5%. Once the owner
decides how documents are refreshed, the figure refreshes with them, because
it rides on the same ingest. That decision is an **open dependency** of this
feature, not something it solves.

### Formula

Applied in `Knowseek.Search` after chunk fusion and grouping, to the document's
best-chunk score, then the hits are sorted again (a stable sort, so equal
scores keep the fused order):

```
factor = 1 + prior_weight * min(1, log10(1 + views) / log10(1 + prior_saturation_views))
score  = rrf_score_of_best_chunk * factor
```

- Defaults: `prior_weight: 0.3`, `prior_saturation_views: 1_000_000`, in
  `config :knowseek, Knowseek.Search`. Both can be overridden per call
  (`Search.search/2` options). A weight of 0 turns the prior off.
- `factor` is in `[1.0, 1.3]`. It never lowers a score, and a missing
  figure (`NULL`) gives exactly `1.0`, so documents without a signal score and
  order exactly as before.
- Bound: a document can gain at most `prior_weight` (30%) over an equally good
  one. An RRF score for rank 1 in both lists is 2/61 = 0.0328, for rank 20 in
  both 2/80 = 0.0250, a ratio of 1.31. So a popular document has to be within
  about 20 ranks (in both lists) of a relevant one to overtake it. A document
  that matched in one list only scores at most 1/61 = 0.0164, and 0.0164 * 1.3
  = 0.0213 is below the score of any document in the top 33 of both lists.
  The relevance floor of ADR 0009 still removes the irrelevant hits before the
  prior is applied.
- Effect: 81,520 views give a factor of 1.245, and 6,276 give 1.190. That is
  a 4.6% lead, about three rank steps at the top (rank 1 to rank 2 in both
  lists is 1.6%), which is what "near-tie" means. Ten times the views is worth
  0.05 of factor (`0.3 / 6`).
- `Hit.score` now includes the factor. `passages[].score` stay chunk scores.

## Consequences

- One new column and one extra query (`documents.id IN (...)`, only for the
  grouped candidates) per search. It is a read join inside `Search` (rule 1).
- The score in the API response includes the prior; the documented maximum of
  the raw RRF score (2/61) no longer holds for documents with a figure.
- The figure can be stale (see above), and it is Wikipedia-specific. Another
  source that has a popularity measure would need a conversion to views per 30
  days or its own column.
- Page views are a measure of attention, not of truth. A news spike lifts a
  page for a month at most 30%.

## Alternatives rejected

- **Wikidata sitelinks.** Stable, but wrong on 2 of 5 ambiguous pairs above,
  and it needs a Wikidata call per candidate and an entity-resolution context.
- **The REST pageviews API per candidate.** The same numbers, one more HTTP
  call per page, and a 429 under load (it rate limited the probes).
- **A refresh job or a cron.** Out of scope until the owner decides how
  documents are refreshed (see above), and ADR 0015 removed the cron.
- **A larger or unbounded prior.** A raw `log(views)` boost lets a popular but
  loosely related page outrank a relevant one. The bound is the point.
- **Penalising documents without a signal.** Unknown is not unpopular: manual
  and future-source documents would drop below every Wikipedia page.
