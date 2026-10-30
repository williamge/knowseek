# 008. Answer synthesis with citations

- Status: open
- Area: new context (for example `Knowseek.Answers`)
- Depends on: 001 (real embeddings make the retrieved context worth summarizing)

## Goal

Return a short written answer to the query, built from the retrieved hits,
with citations to the source documents.

## Scope

- Given a query and hits, call an LLM (Claude via the Anthropic Messages API)
  to write an answer that cites hits by document id or URL.
- Opt-in: `POST /api/search` with `"answer": true`. Default stays search-only.
- Say clearly when the hits do not answer the query. Do not invent facts.
- Stub the LLM in tests.

## Acceptance criteria

- Tests cover the request shape and citation mapping.
- Answer generation errors do not fail the search: return hits plus an
  `answer_error`.
