# 0009. Search returns only relevant hits

- Status: Accepted
- Date: 2026-10-30

## Context

The vector search returns the nearest chunks however far away they are. The
search used to return the top `limit` of the merged results as they were. For a
query that the index did not cover, it returned the least bad chunks. The
coverage assessment said `:none`, but the hits were still in the response.
In the web UI, "octopus" showed the seed documents about pgvector and Oban,
and "heavy metal" showed octopus articles. This looked like a wrong answer.

## Decision

`Knowseek.Search` drops every chunk that is not relevant, before it applies
`limit`. A chunk is relevant when it matched the full-text search, or when its
cosine similarity is at least `min_similarity`
(`Knowseek.Search.Hit.relevant?/2`). `Knowseek.Search.Coverage` uses the same
function, so the hits and the coverage cannot disagree.

A query that the index does not cover returns `hits: []`, `coverage: "none"`,
and a discovery job.

`min_similarity` stays at 0.5 in `config/config.exs`. It depends on the model:

- `bge-m3` (Ollama): off-topic queries scored at most 0.42 against our test
  chunks. On-topic queries scored 0.64 to 0.69 on their best chunk. 0.5 is
  between the two, but the margin is small (the sample was ten queries and
  fourteen chunks).
- Hashing: matches words, so a semantic-only hit rarely reaches 0.5. Keyword
  matches still pass. This is the intended behavior for a stand-in.
- Voyage: not measured.

## Consequences

- The API response changes: `hits` can be empty when it was not before. The
  web UI shows an empty state while discovery runs.
- A relevant chunk with a similarity below the floor and no keyword match is
  hidden. This is better than showing noise, but it can hide a weak match.
- When a model changes, measure on-topic and off-topic scores again and tune
  `min_similarity`. Per-model floors are a possible follow-up.
