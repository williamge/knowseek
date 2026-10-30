# 004. RSS/Atom feed source for topics

- Status: open
- Area: `Knowseek.Discovery`, `Knowseek.Topics`
- Depends on: none

## Goal

Keep followed topics fresh from feeds (news sites, blogs, release notes,
arXiv listings).

## Scope

- A way to attach feed URLs to a topic (new table `topic_feeds` or a field on
  `topics`; pick one and explain why in the Outcome).
- A source or worker that polls a topic's feeds and ingests new entries
  (title, link, summary or content, published date).
- Use conditional GET (`ETag`, `Last-Modified`) to avoid refetching.
- API: add and remove feeds on a topic.

## Acceptance criteria

- Feed parsing tests for RSS 2.0 and Atom fixtures.
- Re-polling an unchanged feed ingests nothing new.

## Notes

Feeds are per-topic, not per-query, so this may fit better as a separate
worker than as a `Discovery.Source`. Decide and document it.
