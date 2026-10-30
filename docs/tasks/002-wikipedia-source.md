# 002. Wikipedia discovery source

- Status: done
- Area: `Knowseek.Discovery`
- Depends on: none

## Goal

Add the first real discovery source. Wikipedia needs no API key and returns
clean text, so it is a good first source.

## Scope

- `Knowseek.Discovery.Sources.Wikipedia` implementing `Knowseek.Discovery.Source`.
- Search with the MediaWiki API (`action=query&list=search`), then fetch plain
  text extracts for the top N results (`prop=extracts&explaintext=1`).
- Return candidates with the canonical page URL, title, body, and
  `metadata: %{"pageid" => ...}`.
- Send a descriptive `User-Agent` (Wikimedia policy).
- Register it in `config/config.exs` (not in `config/test.exs`).

## Acceptance criteria

- Tests use `Req.Test` stubs with recorded-style JSON fixtures. No network.
- Running `Knowseek.Discovery.run("pgvector")` in `iex` against the real API
  ingests documents (manual check, note the result in the Outcome).
- Errors (timeouts, non-200) return `{:error, reason}`.

## Outcome

Built `Knowseek.Discovery.Sources.Wikipedia` (`backend/lib/knowseek/discovery/sources/wikipedia.ex`):

- One `list=search` request, then one `prop=extracts|info|pageprops` request
  per page. MediaWiki returns only one whole-article extract per request, so
  one run fetches its pages one at a time. Every request sends `maxlag=5`.
  Several discovery jobs can still run at the same time.
- Queries are cut to 300 code points at a word boundary. CirrusSearch
  rejects longer queries (`cirrussearch-query-too-long`).
- Candidates use `canonicalurl`, the title, the plain text extract, and
  `metadata: %{"pageid" => ...}`. Missing pages, empty pages, and
  disambiguation pages are skipped.
- Long articles are cut at `max_chars` (default 40,000), at the last
  paragraph break if it is in the second half. Without a cap, one article
  can produce hundreds of chunks, which costs a lot with a paid embedding
  provider.
- Errors return `{:error, reason}`: HTTP errors, timeouts, MediaWiki `error`
  responses, and bodies without the expected `query` data. A failed search
  fails the source. A failed page fetch is logged and skipped. The source
  fails only if every page fetch fails. Req retries transient errors first
  (disabled in tests).
- Settings: `base_url`, `limit` (3), `max_chars`, `user_agent`, `req_options`.
- Registered in `config/config.exs`. `config/test.exs` sets
  `Knowseek.Discovery` `sources: []`, so tests never reach a real source.
- Test fixtures are trimmed real API responses in
  `backend/test/support/fixtures/wikipedia/`.

Manual check (2026-10-30): `Knowseek.Discovery.run("pgvector")` against the
real API returned `{:ok, %{ingested: 2, failed: 0}}`. The search found
"Vector database" and "Hierarchical navigable small world". English
Wikipedia has no "pgvector" article.

Left out:

- Only English Wikipedia. Another language needs a different `base_url`.
- No `published_at`. The API gives the last edit time (`touched`), which is
  not a publication date.
- The search query is the raw user query. Task 007 (query planning) will
  improve recall for long questions.
- A cut can leave a section heading with no text at the end of the body.
  This is cosmetic.

Review fixes (PR #2): unexpected response bodies, the query length limit,
disambiguation pages, partial page failures, early paragraph breaks in
`truncate/2`, and the request etiquette text.

Follow-ups: 015 (retry failed discovery sources) and 016 (limit discovery
abuse) came from the review. 014 (one search hit per document). Long Wikipedia articles
have many chunks, and search returns chunks, so one article can fill the
result list and inflate coverage. Task 007 is now unblocked.
