# 002. Wikipedia discovery source

- Status: open
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
