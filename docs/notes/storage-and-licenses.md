# What Knowseek stores, embeds and shares, and under which license

Issue [#61](https://github.com/williamge/knowseek/issues/61). Not legal advice. Every terms claim was read on 2026-11-06 and cites a numbered source (end of note); `[INFERENCE]` marks my reading where no page settles it.

## Answer

- **Today:** Wikipedia, Wikidata, the SEC, Open-Meteo and balldontlie are fine or fine with small fixes. ESPN was a problem (Disney's terms forbid scripted access); the NBA card moved to balldontlie ([ADR 0028](../decisions/0028-nba-card-source.md)).
- **Keep a license on every document** (`license`, `attribution`, `modified`, `share`). Sharing (#58) filters on it; unknown means not shared.
- **New sources pass the checklist in (c).** Community and public-sector sources mostly pass. Commercial publishers and search APIs mostly fail. So do Stack Exchange and Fandom, whose site terms forbid automated indexing even though their text is CC BY-SA.
- **Peers get text or pointers, never vectors.** Each peer embeds locally, which sidesteps whether an embedding is an adaptation.

## 1. What we store today

From `backend/priv/repo/migrations`, `backend/lib` and `backend/config` at `main`.

| Data | Where | Source | Kept | License or terms | Verdict |
|---|---|---|---|---|---|
| Wikipedia documents: title, URL, plain-text body (cut at 40,000 chars), `metadata.pageid` | `documents` (`source = "wikipedia"`) | MediaWiki Action API, en.wikipedia (`Discovery.Sources.Wikipedia`) | Forever; re-ingest replaces | CC BY-SA 4.0 or GFDL [1] | **Conditional.** Keeping and embedding are fine. Showing the text to anyone but the owner is "Share" [29], which needs a license notice and a "modified" note [1][29]. The reader shows only `source`, a link to the page and the fetch time: add "CC BY-SA 4.0" with a link and "plain-text extract, may be shortened". |
| Manual documents | `documents` (`POST /api/documents`) | Whatever the caller posts | Forever | Unknown | **Conditional.** The operator is responsible. Never share them by default. |
| Chunks | `chunks.content` | Verbatim pieces of a document body | Deleted with the document | Same as the document | Same verdict as the document. |
| Embeddings | `chunks.embedding` | bge-m3 through local Ollama (default); Hashing; Voyage (opt-in) | Deleted with the chunk | Same as the document | **Fine** with Ollama or Hashing. **Conditional** with Voyage: chunk text goes to Voyage, which stores it and trains on it unless the customer opts out, and opting out needs a payment method [9]. CC BY-SA text allows this; a source whose terms ban ML must never go through Voyage. |
| Page views, last revision time | `documents.monthly_views`, `source_updated_at` | Same Wikipedia request (`prop=pageviews`, `prop=revisions`) | With the document | Analytics data CC0 [4] | **Fine.** |
| Alias URLs | `document_aliases` | Our URL canonicalization | With the document | Facts (URLs) | **Fine.** |
| Discovery jobs: `{"query": ...}` | `oban_jobs.args` | The user's query | Pruned after 7 days (`Oban.Plugins.Pruner`) | Our own data (privacy, not licensing) | **Fine.** |
| Entity cache: ids, labels, descriptions, types, coordinates, CIK, tickers | ETS, in memory | Wikidata `wbsearchentities` and `wbgetentities` | 24 h TTL, at most 5,000 entries, lost on restart | CC0 [5] | **Fine.** |
| NBA team card | ETS, in memory | balldontlie free API (`api.balldontlie.io`), a key per operator ([ADR 0028](../decisions/0028-nba-card-source.md)); until #65, ESPN's undocumented site API | 30 s (live game) to 6 h; team list 24 h | balldontlie terms [32]: any lawful use, caching and display allowed, no credit required; keys may not be shared. ESPN's were Disney's Terms of Use [6], which forbid scripted access | **Fine** with the operator's own free key (5 requests a minute). Without a key there is no NBA card. |
| Weather card | ETS, in memory | Open-Meteo free API | 5 to 15 min | CC BY 4.0, free API non-commercial, < 10,000 calls a day [7] | **Fine** as built (credit and license link shown, ADR 0022), **if** the deployment is non-commercial. |
| Company card | ETS, in memory | SEC EDGAR (`data.sec.gov`) | 1 h | "Public information", may be copied [8]. At most 10 requests a second, and no "unclassified" bots [8] | **Fine; conditional** on identification. The default User-Agent `Knowseek/0.1 (self-hosted instance)` has no contact address, so an operator who serves others should set `SEC_USER_AGENT` (ADR 0021). |

**Wikimedia request rules** (Wikipedia source and entity cache). The User-Agent `Knowseek/0.1.0 (https://github.com/williamge/knowseek)` meets the contact rule, which accepts "a website" [2]. Volume is far below 200 requests a minute [3]. Concurrency: Wikimedia asks for "3 or fewer" concurrent requests "across all sites" [3]. Up to 5 discovery jobs, each fetching pages one at a time, plus 4 Wikidata resolutions could mean 9 at once. Fixed in #66: `Knowseek.Wikimedia` caps them at 3, entity lookups first ([ADR 0027](../decisions/0027-wikimedia-concurrency-cap.md)).

## 2. Per source: keep, embed, share (question a)

"Share" means to peers (#58): **full** text, a **pointer** (URL and title), or **no**.

| Source | Keep | Embed | Share | Search API, breadth | Key terms |
|---|---|---|---|---|---|
| Wikipedia and other Wikimedia wikis | Yes | Yes | Full, with attribution and share-alike | Action API `list=search`; en.wikipedia has 7,259,973 articles (siteinfo) | CC BY-SA 4.0 or GFDL; credit by link to the page [1]; ≤ 3 concurrent requests [3] |
| Wikidata | Yes | Yes | Full | `wbsearchentities`; 123,947,475 content pages | CC0 [5] |
| Stack Exchange | License yes; API content is exempt from the ToS storage ban [10] | **No** without written consent [11] | Pointer | `/2.3/search/advanced`; Stack Overflow has 24.2M questions and 36.1M answers (`/info`). Quota without a key: `quota_max: 300` a day (observed, no doc page states it); with a key, 10,000 a day by default [12]; > 30 requests a second per IP are dropped [12] | The Acceptable Use Policy bans automated access to "any Network website or Service" for "indexing … or improving any … machine learning tool" [11]. License by post date: CC BY-SA 2.5 / 3.0 / 4.0 [14]. Attribution: link the question, show each author's name linked to their profile, no `nofollow` [15], and show Stack Exchange as the source [13] |
| Fandom wikis | **No** | **No** | No | MediaWiki API answers at `<wiki>.fandom.com/api.php`; starwars has 236,947 articles | Text is CC BY-SA 3.0, some wikis NC [16], but the ToU forbid robots that "scrape, extract, retrieve or index" content, and AI training [17]. Needs written permission |
| OpenAlex | Metadata yes | Yes | Full metadata; full text only under an open per-work license | `api.openalex.org/works?search=`; "protein" gives 12.9M hits | CC0 [18]; optional key; 10 req/s without one; a small daily budget per IP [18] |
| arXiv | Metadata yes; full text personal or research use only | Metadata yes | Metadata full; papers pointer | `export.arxiv.org/api/query`; "electron" gives 188,579 hits | Metadata CC0; don't "store and serve" e-prints [19]; 1 request every 3 s; an acknowledgement line is required [19] |
| Europe PMC | OA subset yes, per article license; the rest no | OA subset yes | OA subset per license; the rest pointer | REST `search`; 49.2M records, 8.4M OA (live) | "refer to the license statement in each article"; most full text is under traditional copyright [20]. Copyright and REST terms pages were blocked (403): **unverified** |
| Open Library | Metadata yes `[INFERENCE]` | Yes `[INFERENCE]` | Pointer (no explicit license) | `openlibrary.org/search.json`; "dune" gives 48,281 hits | "does not assert any new copyright" but names no license; not "a bulk data backend"; 1 req/s, 3 with a User-Agent and email [21] |
| Project Gutenberg | Yes (US public domain) | Yes | Full (US); per-book copyright flag | No official API; the site is "for human users only"; use mirrors or a self-hosted Gutendex; 75,000+ books | Most books are public domain in the US; catalog public domain [22] |
| Federal Register | Yes | Yes | Full | `federalregister.gov/api/v1/documents.json?conditions[term]=`; no key [24] | US government works carry no copyright [23] |
| Library of Congress | Per item | Per item | Pointer unless the item is public domain | `loc.gov/search/?q=…&fo=json`; no key; 20 to 150 req/min, 1-hour block when exceeded [25] | LoC "generally do[es] not own the rights" [25] |
| OpenStreetMap / Nominatim | Yes, under ODbL | Yes `[INFERENCE]`; the index is likely a Derivative Database [26] | Full under ODbL only | Nominatim `search`; ≤ 1 req/s; "Results must be cached"; no periodic or bulk use [28] | Share-alike for databases; credit "© OpenStreetMap contributors" [26][27]. Not a text source; places already come from Wikidata |
| Global Voices | Yes | Yes | Full, with attribution | WordPress `/wp-json/wp/v2/posts?search=` | CC BY 3.0 "unless otherwise stated" [31] |
| Tavily | Yes | Yes | **No** (internal use only) | Paid search API | [31] |
| Brave Search, Exa | **No** (transient only) | No | No | Paid search APIs | [31] |
| NYT | Summaries and links only | **No** | No | Article Search API | [31] |
| The Guardian | 24 h only | **No** | No | Content API | [31] |

## 3. A license on every document (question b)

**Yes.** Licenses vary *within* a source (Fandom per wiki, Stack Exchange by post date, Europe PMC and OpenAlex per work, Gutenberg per book), so a per-source rule is not enough. Built in #68 as below; see [ADR 0026](../decisions/0026-per-document-license-fields.md):

| Field | Example | Why |
|---|---|---|
| `license` | SPDX id: `CC-BY-SA-4.0`, `CC0-1.0`, `CC-BY-4.0`, `ODbL-1.0`, `LicenseRef-PD-US`, `LicenseRef-unknown` | Decides what a peer may receive |
| `attribution` | `{url, credit: "Wikipedia", authors: [...]}` (authors only where the license needs them, as on Stack Exchange) | What BY needs [29] |
| `modified` | `true` for Wikipedia (a plain-text extract, maybe shortened) | BY 4.0 3(a)(1)(B) [29] |
| `share` | `full`, `pointer` or `none` | Site terms that aren't in the license (arXiv, the Stack Exchange AUP, Tavily) |

The source module sets these at ingest. Missing means `LicenseRef-unknown` and `none`, which covers manual documents. Existing Wikipedia rows are backfilled with a constant. Columns rather than `metadata` keys, because sharing filters on them. Chunks and embeddings inherit from their document.

## 4. Test for a new source (question c)

A source is added only if every box is ticked, with a link and a quote for each in its ADR (as in ADRs 0021 and 0022):

- [ ] **Scripted access allowed.** An API, or terms and `robots.txt` that permit a script. No account or paid plan required for normal use.
- [ ] **Permanent storage allowed.** Not "transient", not "delete within N hours".
- [ ] **Indexing and ML not banned.** Treat local embedding as ML.
- [ ] **License known per document**, from the API response or a fixed rule (by date, per wiki, per work). Unknown means `share: none`.
- [ ] **Attribution possible** from what we store (URL, credit, authors if needed).
- [ ] **Search API** that answers a free-text query, under a rate limit we can keep with single flight and backoff. No key, or a free key.
- [ ] **Breadth:** three sample queries that Wikipedia answers badly and this source answers well.
- [ ] **Courtesy:** a User-Agent with contact info; honour 429, `Retry-After` and `maxlag`; respect the concurrency limit.
- [ ] **Share level** (`full`, `pointer` or `none`) written down.

## 5. What attribution and share-alike licenses require (question d)

"Share" means "to provide material to the public" [29]. ODbL's "Publicly" means "to Persons other than You or under Your control" [26]. **An instance only its owner uses isn't sharing** `[INFERENCE]`. An instance others can reach, and every peer, is.

| License | Instance that shows the content | Peer that re-shares |
|---|---|---|
| CC0, US public domain | Nothing (credit is a courtesy) | Nothing |
| CC BY 4.0 (Open-Meteo, Global Voices 3.0) | Credit, a link to the source, the license name and link, and "modified" if changed [29] | The same, passed along unchanged. No terms that restrict the licensed material [29] |
| CC BY-SA 4.0 (Wikipedia, recent Stack Exchange) | As for CC BY. For Wikimedia, a link to the page credits the authors [1]. Stack Exchange wants author names and profile links [15] | As for CC BY. An adaptation must be CC BY-SA 4.0 or later, or compatible [29]. No added terms or DRM [29] |
| CC BY-SA 3.0 / 2.5 (Fandom, older Stack Exchange) | Same idea; attribution per [16] or [15] | Same idea, under that version |
| ODbL 1.0 (OSM) | A produced work needs a notice such as "© OpenStreetMap contributors" [26][27] | A derivative database must be ODbL, with a machine-readable copy offered [26] |

**Chunks.** A chunk is a verbatim excerpt, so sharing it shares the licensed text: full attribution, the license, and a note that it's an excerpt. Whether excerpting creates "Adapted Material" [29] is unclear. Conservative reading: treat it as an adaptation and keep the same license.

**Embeddings: unsettled.** CC's guidance says its licenses apply "only when copyright permission is required" and that BY and SA are "triggered only when works or adaptations … are publicly shared". It doesn't address embeddings [30]. Conservative reading: an embedding carries its document's license and attribution, and is never shared without them. In practice, don't share vectors: they only compare within one model (ADR 0016), so peers re-embed anyway.

Knowseek's AGPL covers our code, not the content. Content licenses apply separately.

## 6. Implications for #58

| Share as | Sources |
|---|---|
| **Full text** (with the `license` and `attribution` record) | Wikipedia and other Wikimedia wikis, Wikidata, Federal Register, Project Gutenberg (US public domain), Global Voices, OpenAlex metadata, arXiv metadata, Europe PMC and OpenAlex works with an open license, OSM data (under ODbL only) |
| **Pointer** (URL and title) | arXiv papers, Europe PMC non-OA, Library of Congress items that aren't public domain, Open Library, Stack Exchange (if ever added with consent) |
| **Never** | Card caches (balldontlie, Open-Meteo, SEC: live, in memory, not documents), Tavily, Brave, Exa, NYT, Guardian, Fandom, manual documents with no license, embeddings (peers re-embed) |

## Unverified

- Europe PMC's copyright and REST terms pages (403 from Cloudflare). The OA-subset page was read.
- Stack Exchange's 300-a-day keyless quota: observed in a live response, not in the docs. The keyed quota wasn't tested (getting a key needs a Stack Apps registration).
- Whether the Stack Exchange AUP's "Service" includes the API: my reading is that it does.
- Whether embeddings, or chunks, are adaptations (section 5).
- Fandom's total size, and Open Library's and the Library of Congress's corpus sizes.
- Wikimedia's REST search endpoint (not read). The Wikimedia Terms of Use were searched for storage limits, not read in full.
- The Brave, Exa, Tavily, NYT, Guardian and Global Voices rows reuse the #61 comment (read 2026-11-06) and weren't re-read.

## Sources (read 2026-11-06)

1. [Wikimedia Terms of Use](https://foundation.wikimedia.org/wiki/Policy:Terms_of_Use): "Reusers may comply with either license or both."; "Through hyperlink (where possible) or URL to the page or pages that you are reusing"; "you agree to clearly indicate that the original work has been modified."
2. [User-Agent policy](https://foundation.wikimedia.org/wiki/Policy:User-Agent_policy): "The contact information should be given as an email address, a website, or a wiki user".
3. [Wikimedia API rate limits](https://www.mediawiki.org/wiki/Wikimedia_APIs/Rate_limits): "Rate limits apply across all sites and platforms"; "limit the number of concurrent requests to 3 or fewer."; a compliant User-Agent gets 200 requests a minute; "new in 2026".
4. [Wikimedia dumps licensing](https://dumps.wikimedia.org/legal.html): "All Analytics datasets are available under the Creative Commons Zero (CC0) public domain dedication, unless otherwise specified."
5. [Wikidata:Licensing](https://www.wikidata.org/wiki/Wikidata:Licensing): "All structured data (i.e. the main, Property, Lexeme, and EntitySchema namespaces) is released into the public domain under Creative Commons Zero".
6. [Disney Terms of Use](https://disneytermsofuse.com/english/) (the espn.com footer links here): "access, monitor, copy or extract the Disney Products using a robot, spider, script, or other automated means"; "for your personal, noncommercial use only".
7. [Open-Meteo terms](https://open-meteo.com/en/terms): "You may only use the free API services for non-commercial purposes. You accept to the CC-BY 4.0 licence"; "Less than 10'000 API calls per day".
8. [SEC privacy and website policies](https://www.sec.gov/privacy): "Information presented on sec.gov is considered public information and may be copied or further distributed"; "no more than 10 requests per second"; "The SEC does not allow "unclassified" bots or automated tools to crawl the site."
9. [Voyage AI FAQ](https://docs.voyageai.com/docs/faq): "customers can opt-out from Voyage storing and using their data for future model training"; "you must have a payment method on file".
10. [Stack Overflow Terms of Service](https://stackoverflow.com/legal/terms-of-service/public): "(other than Subscriber Content or content made available via the Stack Overflow API)"; "all such Public Content must have appropriate attribution."
11. [Stack Overflow Acceptable Use Policy](https://stackoverflow.com/legal/acceptable-use-policy): "Developing, building, training, testing, indexing, benchmarking, or improving any generative AI, chatbot, large language, or machine learning tool"; "exempt from this policy if you have obtained express prior written consent."
12. [Stack Exchange API throttles](https://api.stackexchange.com/docs/throttle): "the daily request limit for the applications involved, which by default is 10,000."; "more than 30 requests a second, new requests will be dropped."
13. [Stack Exchange API terms](https://stackexchange.com/legal/api-terms-of-use): "visually indicate that the Stack Exchange Network is the source of the content".
14. [Stack Overflow licensing](https://stackoverflow.com/help/licensing): "Content contributed before 2011-04-08 (UTC) is distributed under the terms of CC BY-SA 2.5."; "on or after 2018-05-02 (UTC) … CC BY-SA 4.0."
15. [Attribution Required (2009)](https://stackoverflow.blog/2009/06/25/attribution-required/): "Show the author names for every question and answer"; "Hyperlink each author name directly back to their user profile page"; "the links must not be nofollowed."
16. [Fandom licensing](https://www.fandom.com/licensing): "licensed under the Creative Commons Attribution-Share Alike License 3.0 (Unported)"; "Some wikis use licenses other than the CC BY-SA license."
17. [Fandom Terms of Use](https://www.fandom.com/terms-of-use): "Use any robot, spider, site search and/or retrieval application, or other device to scrape, extract, retrieve or index any portion of the content"; "training a machine learning or artificial intelligence (AI) system".
18. [OpenAlex overview](https://help.openalex.org/access/overview.md): "all the data is free and open under CC0."; [authentication](https://help.openalex.org/api/authentication/): "you can make basic queries with no key at all"; [full text](https://help.openalex.org/access/fulltext.md): "use the `best_oa_location.license` field".
19. [arXiv API terms of use](https://info.arxiv.org/help/api/tou.html): metadata "under the terms of the … (CC0 1.0)"; "for your own personal use, or for research purposes"; "no more than one request every three seconds". [API page](https://info.arxiv.org/help/api/index.html): "Thank you to arXiv for use of its open access interoperability."
20. [Europe PMC open access subset](https://europepmc.org/downloads/openaccess): "Please refer to the license statement in each article for specific terms of use."; "The majority of the full text articles in Europe PMC are subject to traditional copyright restrictions".
21. [Open Library licensing](https://openlibrary.org/developers/licensing): "does not assert any new copyright"; [API](https://openlibrary.org/developers/api): "not intended to serve as a bulk data backend"; "Identified requests (with User-Agent and email): 3 requests per second".
22. [Gutenberg permissions](https://www.gutenberg.org/policy/permission.html): "The vast majority of Project Gutenberg eBooks are in the public domain in the US."; [terms](https://www.gutenberg.org/policy/terms_of_use.html): "This website is intended for human users only."; [robot access](https://www.gutenberg.org/policy/robot_access.html): "The catalog data are granted to the public domain."
23. [17 U.S.C. § 105](https://www.law.cornell.edu/uscode/text/17/105): "Copyright protection under this title is not available for any work of the United States Government".
24. [Federal Register API](https://www.federalregister.gov/developers/documentation/api/v1): "FederalRegister.gov APIs do not require API keys".
25. [Library of Congress legal](https://www.loc.gov/legal/): "we generally do not own the rights to materials in our collections"; [API limits](https://www.loc.gov/apis/json-and-yaml/working-within-limits/): "Requests that exceed the rate … will be blocked", one hour.
26. [ODbL 1.0](https://opendatacommons.org/licenses/odbl/1-0/): "“Publicly” – means to Persons other than You or under Your control"; a Derivative Database includes "Extracting or Re-utilising the whole or a Substantial part of the Contents in a new Database"; "You must also offer … a copy in a machine readable form".
27. [OSMF attribution guidelines](https://osmfoundation.org/wiki/Licence/Attribution_Guidelines): "“© OpenStreetMap contributors” or “© OpenStreetMap” are acceptable."
28. [Nominatim usage policy](https://operations.osmfoundation.org/policies/nominatim/): "an absolute maximum of 1 request per second"; "Results must be cached on your side."; "periodic requests from apps are considered bulk geocoding".
29. [CC BY-SA 4.0 legal code](https://creativecommons.org/licenses/by-sa/4.0/legalcode.en): 1(k) "Share means to provide material to the public"; 3(a)(1)(B) "indicate if You modified the Licensed Material"; 3(a)(2) "providing a URI or hyperlink to a resource that includes the required information"; 3(b)(1) "a Creative Commons license with the same License Elements, this version or later"; 3(b)(3) "You may not offer or impose any additional or different terms or conditions".
30. [CC: using CC-licensed works for AI training](https://creativecommons.org/using-cc-licensed-works-for-ai-training-2/): "CC licenses apply only when copyright permission is required."; "triggered only when works or adaptations of works are publicly shared."
31. [#61 comment](https://github.com/williamge/knowseek/issues/61) (2026-11-06): Brave, Exa, Tavily, NYT, The Guardian and Global Voices, each quoted from its own terms.
32. [balldontlie Terms of Service](https://www.balldontlie.io/terms) (read for #65): "You may use Data for any lawful personal or commercial purpose"; "copying, caching, storing, archiving, modifying, combining, analyzing, publishing, displaying"; "No attribution … is required"; "API keys and account credentials may not be shared".
