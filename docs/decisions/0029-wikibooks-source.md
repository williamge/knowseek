# 0029. Wikibooks source

- Status: Accepted
- Date: 2026-11-06

Related: issue [#73](https://github.com/williamge/knowseek/issues/73),
[how-to sources](../notes/how-to-sources.md) (#69, the evidence),
[storage and licenses](../notes/storage-and-licenses.md) (section 4, the
checklist), [0018](0018-ranking-prior.md) (ranking prior),
[0026](0026-per-document-license-fields.md) (license fields),
[0027](0027-wikimedia-concurrency-cap.md) (Wikimedia cap).

## Context

Wikipedia says what a thing is, not how to do it. For "fix a flat bicycle
tire" it returns *Flat tire*; Wikibooks returns *Bicycles/Maintenance and
Repair/Wheels and Tires/Fixing a flat*. The how-to note found Wikibooks the
only how-to source that passes every box of the new-source test, under the
same terms and the same Action API as the Wikipedia source.

But Wikibooks is small (99,158 content pages) and uneven: for a name like
"Barack Obama" its search returns off-topic book pages.

## Decision

1. **A shared MediaWiki module.** The MediaWiki code moves from
   `Discovery.Sources.Wikipedia` to `Discovery.Sources.MediaWiki`, which takes
   a site: source name, `api.php` URL, license, credit and config key.
   `Sources.Wikipedia` and `Sources.Wikibooks` are thin modules over it.
   Wikipedia's requests and candidates do not change.
2. **`Sources.Wikibooks`**: `en.wikibooks.org`, source `"wikibooks"`, the same
   requests as Wikipedia (`list=search` in namespace 0, then
   `prop=extracts|info|pageprops|pageviews|revisions` per page, `maxlag=5`),
   `license: "CC-BY-SA-4.0"`, attribution `{url: <page URL>, credit:
   "Wikibooks", authors: []}`, `modified: true`, `share: "full"`. Its requests
   are `:background` callers of `Knowseek.Wikimedia` (ADR 0027): the 3 slots
   are shared across Wikipedia, Wikibooks and Wikidata.
3. **Only for questions.** `Wikibooks.discover/2` returns `{:ok, []}` without
   a request unless `Wikibooks.question?/1` holds: the query ends with `?`, or
   starts with one of how, why, can, could, should, do I, is it, what's the
   best, what is the best (any case, whole word; `whats` and `what’s` count).
   These ask for a method, a reason or advice. "What is X" and "who" ask what
   something is, which Wikipedia answers. Wikipedia runs for every query.
4. **Page views are kept, on their own scale** (below).

### Where the gate lives

In the source, not in `Discovery`. `discover/2` returning `{:ok, []}` is
already in the `Source` contract, so `Discovery` stays generic and the
behaviour is unchanged. An optional callback (say `accepts?/1`) would give
`Discovery` a second way to skip a source, for one source; revisit it when a
second source needs a gate.

### Page views

The Wikipedia request's `prop=pageviews` works on Wikibooks (live,
2026-11-06): 60 daily figures per page, from the same Wikimedia pipeline, so
`monthly_views` has the same unit. The audience is much smaller:

| Subject | Wikibooks page, views per 30 days | Wikipedia page, views per 30 days |
| --- | --- | --- |
| Flat tire | *Bicycles/…/Fixing a flat*: 238 | *Flat tire*: 896 |
| Bowline | *Knots/Loop knots/Bowline*: 212 | *Bowline*: 3,978 |
| SSH keys | *OpenSSH/Cookbook/Public Key Authentication*: 860 | *Secure Shell*: 43,212 |

The ranking prior (ADR 0018) is `1 + 0.3 * log10(1 + views) / log10(1 +
1,000,000)`: 1.119, 1.116 and 1.147 for the Wikibooks pages, 1.148, 1.180 and
1.232 for the Wikipedia ones. So of two equally relevant hits on one subject,
the Wikipedia page scores 3% to 7% higher here. We keep the figure anyway: it is the same
measurement, it still orders Wikibooks pages among themselves, and leaving it
out would give a factor of 1.0, lower still. A per-source scale is a change to
ADR 0018, not to this source; revisit it if Wikibooks pages lose to weaker
Wikipedia hits in practice.

### New-source checklist

From [storage and licenses, section 4](../notes/storage-and-licenses.md#4-test-for-a-new-source-question-c).
Quotes read 2026-11-06 (the how-to note), checked again live where marked.

| Box | Evidence |
| --- | --- |
| **Scripted access allowed** ✓ | The Action API is meant for scripts. [Wikimedia APIs/Rate limits](https://www.mediawiki.org/wiki/Wikimedia_APIs/Rate_limits): a client with a compliant User-Agent gets 200 requests a minute; "Rate limits apply across all sites and platforms". No key, no account. |
| **Permanent storage allowed** ✓ | [Wikimedia Terms of Use](https://foundation.wikimedia.org/wiki/Policy:Terms_of_Use): the text is free to reuse under its license, "Reusers may comply with either license or both." No time limit found (the terms were searched for storage limits, not read in full). |
| **Indexing and ML not banned** ✓ | Neither the Terms of Use nor CC BY-SA 4.0 bans them. [CC on AI training](https://creativecommons.org/using-cc-licensed-works-for-ai-training-2/): "CC licenses apply only when copyright permission is required." Embedding is local (bge-m3). |
| **License known per document** ✓ | A fixed rule. `siteinfo` `rightsinfo` of [en.wikibooks.org](https://en.wikibooks.org/w/api.php?action=query&meta=siteinfo&siprop=rightsinfo) (checked live): "Creative Commons Attribution-Share Alike 4.0". Like Wikipedia, CC BY-SA 4.0 or GFDL; we record `CC-BY-SA-4.0`. |
| **Attribution possible** ✓ | Terms of Use: credit "Through hyperlink (where possible) or URL to the page or pages that you are reusing", and "you agree to clearly indicate that the original work has been modified." We store the page URL, credit "Wikibooks" and `modified: true`. |
| **Search API** ✓ | `en.wikibooks.org/w/api.php?action=query&list=search`, no key, 200 requests a minute (above). |
| **Breadth** ✓ | [How-to note](../notes/how-to-sources.md#search-api-quota-sample-queries): "fix a flat bicycle tire" → *Bicycles/…/Fixing a flat*; "set up ssh keys" → #2 *OpenSSH/Cookbook/Public Key Authentication*; "tie a bowline knot" → *Knots/Loop knots/Bowline*. Wikipedia: *Flat tire*, *Secure Shell*, *Bowline*, what the thing is. Misses: "bake sourdough bread", "unclog a drain". |
| **Courtesy** ✓ | User-Agent `Knowseek/0.1.0 (https://github.com/williamge/knowseek)`; the [User-Agent policy](https://foundation.wikimedia.org/wiki/Policy:User-Agent_policy) accepts "a website". `maxlag=5` on every request; Req retries 429 and 503 after `Retry-After`. Concurrency: "limit the number of concurrent requests to 3 or fewer" across all sites, kept by `Knowseek.Wikimedia` (ADR 0027). |
| **Share level** | `full`, with the license and attribution. |

## Consequences

- A question can add up to 3 Wikibooks pages to a discovery run, so a run
  takes longer: the requests share the Wikimedia slots and each page is
  embedded (about 1.4 s per 20 chunks with local Ollama).
- Many questions still find nothing useful: Wikibooks is small, and its
  search returns book pages for any word they contain.
- Recipes are missed: Wikibooks keeps them in the `Cookbook:` namespace (102),
  which the namespace-0 search does not cover ("sourdough bread" in 102 finds
  *Cookbook:San Francisco Sourdough Bread*; "how do i bake sourdough bread" in
  0 finds off-topic pages). Searching it is a follow-up.
- "Print version" pages hold whole books; they are cut at 40,000 characters
  like any long page.
- A query starting with "can" or "should" that is not a question ("can
  opener") also asks Wikibooks; a question without a question word or `?`
  ("fix a flat tire") does not.
- A new MediaWiki site is a thin module with its site settings.
