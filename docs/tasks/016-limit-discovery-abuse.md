# 016. Limit discovery abuse

- Status: parked (needs 009, which is parked)
- Area: `Knowseek.Lookup`, `Knowseek.Discovery`, sources
- Depends on: 009 (users and API keys) for per-user limits

## Goal

Stop one caller from making Knowseek send many expensive or unwanted
requests to external sources.

## Context

Any caller of `POST /api/search` controls the query text, and weak coverage
sends that text to every discovery source. The source requests use the
Knowseek User-Agent (or API key), so the service carries the reputation:

- Wikipedia: CirrusSearch operators such as `insource:/regex/` are
  expensive. Repeated abuse can make Wikimedia rate-limit or block the
  Knowseek User-Agent, and then discovery stops for all users.
- Paid sources (task 003) cost money per request.

Found in the review of task 002 (PR #2).

## Scope

- Rate-limit discovery requests: per user when task 009 lands, and a global
  cap per source. Requests over the limit still return search results, with
  a discovery status such as `rate_limited`.
- Wikipedia: remove or neutralize expensive CirrusSearch operators
  (`insource:`, regex, `prefer-recent:`, and similar) before the query is
  sent. List the operators and the reasons in the Outcome.
- Log or count refused requests (see task 010).

## Acceptance criteria

- Tests for the rate limit (over the limit: no job enqueued, the status is
  reported).
- Tests for operator removal in the Wikipedia source.
