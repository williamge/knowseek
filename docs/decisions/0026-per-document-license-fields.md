# 0026. Per-document license fields

- Status: Accepted
- Date: 2026-11-06

Related: issue [#68](https://github.com/williamge/knowseek/issues/68),
[storage and licenses](../notes/storage-and-licenses.md) (section 3),
[local-first sharing](../notes/local-first-sharing.md) (#58, record format
v1), #67 (the reader notice that reads these fields).

## Context

Licenses vary within a source (Fandom per wiki, Stack Exchange by date,
OpenAlex and Europe PMC per work), so a rule per source is not enough. The
reader must credit CC BY-SA text (#67), and sharing between instances (#58)
must know what a peer may receive. Today a document records neither.

## Decision

1. Four columns on `documents`:

   | Column | Type | Null | Default | Meaning |
   | --- | --- | --- | --- | --- |
   | `license` | varchar | no | `'LicenseRef-unknown'` | SPDX id, for example `CC-BY-SA-4.0`, `CC0-1.0` |
   | `attribution` | jsonb | yes | none | `{url, credit, authors}`: who to credit and where |
   | `modified` | boolean | no | `false` | the text differs from the source's (CC BY 4.0 3(a)(1)(B)) |
   | `share` | varchar | no | `'none'` | `full`, `pointer` or `none`, a CHECK constraint |

   `attribution` is an embedded schema (`Knowseek.Documents.Attribution`): `url` and
   `credit` required, `authors` a list of strings, default `[]`.
2. The source sets them per document, at ingest, as optional candidate keys.
   Wikipedia sets `CC-BY-SA-4.0`, `{url: <page URL>, credit: "Wikipedia",
   authors: []}`, `modified: true` (a plain-text extract, maybe cut) and
   `share: full`. Wikipedia text is CC BY-SA 4.0 or GFDL, and reusers may pick
   either; we record CC BY-SA 4.0. Manual (`POST /api/documents`) and seed
   documents get the defaults unless the caller passes the fields.
3. Unknown means `LicenseRef-unknown`, `attribution: null`, `modified: false`,
   `share: none`: an unknown document is never shared.
4. `Documents.ingest/1` treats them like `monthly_views`: a given field
   overwrites, even when the body is unchanged (no re-chunk); a field left out
   keeps the stored value. An explicit `null` for `license`, `modified` or
   `share` is a changeset error, not an erase. When a URL is only an alias or
   a copy of another document's body, the original keeps its fields.
5. The migration backfills existing rows: `source = 'wikipedia'` gets the
   Wikipedia values above, every other row the defaults.
6. The JSON API exposes all four on documents (index and show) and on search
   hits, with the same names; `frontend/src/types.ts` mirrors them. The names
   match the top-level keys a #58 record would carry; a record leaves out a
   null `attribution`.

## Rejected options

- **Keys in `metadata`.** Sharing filters on `license` and `share`, so they
  belong in columns with constraints.
- **A license per source.** Wrong for sources whose license varies per
  document (Context).
- **Backfill everything as unknown.** Every existing Wikipedia row would lose
  its credit line in the reader, although its license is certain.

## Consequences

- A new source must set the four fields, or its documents are unknown and
  never shared (the checklist in the storage note).
- Chunks and embeddings carry no license of their own; they inherit the
  document's.
- The display name and link of a license id are the frontend's (#67).
- A concurrent first insert of one URL takes the upsert's
  `replace_all_except` path, so a racing insert without the fields can write
  the defaults over another's values, as for the other optional fields.
