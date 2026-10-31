# 004. RSS/Atom feed source

- Status: open
- Area: `Knowseek.Discovery`
- Depends on: none

**Needs rescoping after 028: it is written around topics, which were removed (ADR 0015)**

> Note: this task was written when topics existed. Topics were removed
> (task 026, ADR 0015), so "attach feeds to a topic" and "API: add and remove
> feeds on a topic" no longer have anything to attach to. Task 027 decides what
> following is, with this source as a prerequisite. Reconsider the scope of
> this task before you start it.

## Goal

Poll feeds (news sites, blogs, release notes,
arXiv listings) and ingest new entries.

## Scope

- A way to configure feed URLs (decide where they live and explain why in the
  Outcome).
- A source or worker that polls the feeds and ingests new entries
  (title, link, summary or content, published date).
- Use conditional GET (`ETag`, `Last-Modified`) to avoid refetching.

## Acceptance criteria

- Feed parsing tests for RSS 2.0 and Atom fixtures.
- Re-polling an unchanged feed ingests nothing new.

## Notes

Feeds are per-feed, not per-query, so this may fit better as a separate
worker than as a `Discovery.Source`. Decide and document it.
