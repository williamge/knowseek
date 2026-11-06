# How-to sources we may index

Issue [#69](https://github.com/williamge/knowseek/issues/69). Not legal advice. Every terms claim was read on 2026-11-06 and cites a numbered source (end of note); `[INFERENCE]` marks my reading where no page settles it. The boxes are the new-source test in [storage and licenses, section 4](storage-and-licenses.md#4-test-for-a-new-source-question-c).

## Verdict

✓ passes, ✗ fails, ~ conditional, – not reached (an earlier box failed).

| Source | Script | Store | Index, ML | License | Credit | Search API | Breadth | Courtesy | Share | Verdict |
|---|---|---|---|---|---|---|---|---|---|---|
| **Wikibooks** | ✓ [1] | ✓ | ✓ | ✓ CC BY-SA 4.0 | ✓ link | ✓ | ✓ | ✓ shared Wikimedia budget [1] | full | **Pass** |
| Wikiversity | ✓ [1] | ✓ | ✓ | ✓ CC BY-SA 4.0 | ✓ link | ✓ | ~ thin | ✓ shared Wikimedia budget | full | Pass, thin |
| ArchWiki | ✓ [3] | ✓ | ✓ | ✓ GFDL 1.3+ | ✓ link | ~ every word must match; no `extracts` | ~ Linux only | ✓ | full, GFDL | Pass, Linux only |
| Appropedia | ✓ [2] | ✓ | ✓ | ✓ CC BY-SA 4.0 default; per page | ✓ link | ✓ | ~ sustainability niche | ✓ | full | Pass, niche |
| MDN | ~ pages yes, `/api/` disallowed [5] | ✓ | ✓ | ✓ CC BY-SA 2.5+ | ✓ "Mozilla Contributors" | ~ title index only | ~ web dev only | ✓ | full | Conditional |
| Gentoo wiki | ✗ robots disallows `/api.php` [4] | ✓ | ✓ | ✓ CC BY-SA 4.0 | ✓ | ✗ | – | – | full | Fail |
| iFixit | ~ free key required from 2027-01-01 [6] | ✓ | ~ "training" banned | ✓ CC BY-NC-SA 3.0 | ~ must show parts links | ✗ `/api/2.0/search` disallowed; 1,000 content calls a month | ~ devices only | ✓ | pointer | Fail for now |
| wikiHow | ✗ [7] | ✗ | ✗ AI "retrieval" banned | ✗ CC ended 2025-03-24 | – | – | – | – | none | Fail |
| Instructables | ✗ no API; Autodesk AUP bans indexing [8] | – | – | ~ per project, some NC | – | ✗ | – | – | none | Fail |
| Stack Exchange data dump | ✗ login and a click per site [9] | ✓ | ~ only LLM training banned | ✓ by date | ✓ | ✗ bulk file | ✓ | – | pointer | Fail as a source (below) |
| Stack Exchange API | ✓ | ✓ | ✗ AUP [9] | ✓ | ✓ | ✓ | ✓ | ✓ | pointer | Fail ([#62](https://github.com/williamge/knowseek/issues/62)) |
| Debian wiki | ✓ crawl delay 20 s [10] | – | – | ✗ unknown | – | ✗ no API | – | – | none | Fail |
| Ubuntu wiki, docs | ✗ wiki robots disallows `/w/`; site terms personal use only [11] | ✗ | – | ✗ not stated on docs | – | ✗ | ✗ wiki has 73 articles | – | none | Fail |
| OpenStax | – no API [12] | ✓ | ✓ | ✓ CC BY-NC-SA 4.0 default | ✓ | ✗ | ✗ textbooks, not how-to | – | pointer | Not how-to |
| LibreTexts | ✗ robots disallows `/@*` (API) and `Special:` [13] | ✓ | ✓ | ✓ per page | ✓ | ✗ | ✗ academic | – | – | Fail |

## Recommendation

**Build Wikibooks next.** It ticks every box under the same Wikimedia terms and the same Action API as the Wikipedia source. The exact request the Wikipedia source sends (`list=search`, then `prop=extracts|info|pageprops|pageviews|revisions`) works on `en.wikibooks.org` (tested: text, URL, page views and revision time all come back), so the new source is the Wikipedia module with another `base_url`, source name and credit, `license = CC-BY-SA-4.0`, `share = full`. It gives steps where Wikipedia gives a description (fixing a flat, SSH keys, a bowline), but it is small (99,158 content pages) and uneven: sourdough and unclogging a drain return off-topic book pages, so the coverage check has to judge results, not hit counts. One risk: Wikimedia's "3 or fewer" concurrent requests apply "across all sites" [1], so the concurrency cap from the storage note must cover Wikipedia, Wikidata and Wikibooks together. **ArchWiki** is the best second source (Linux how-to; needs shorter queries and HTML-to-text, since it has no `TextExtracts`), then **Appropedia**. Nothing that passes covers home repair or cooking broadly: wikiHow forbids it outright, and iFixit's key, quota and parts-link rules make it a poor fit.

## Search API, quota, sample queries

Run 2026-11-06 with User-Agent `Knowseek-research/0.1 (https://github.com/williamge/knowseek)`. "→" is the top hit unless noted.

| Source | Search call | Quota | Query → result |
|---|---|---|---|
| Wikibooks | `en.wikibooks.org/w/api.php?action=query&list=search` | 200 req/min with a contact User-Agent; ≤ 3 concurrent across all Wikimedia sites [1] | "fix a flat bicycle tire" → *Bicycles/…/Fixing a flat*; "set up ssh keys" → #2 *OpenSSH/Cookbook/Public Key Authentication*; "tie a bowline knot" → *Knots/Loop knots/Bowline*. Misses: "bake sourdough bread", "unclog a drain" |
| Wikipedia, same queries | (baseline) | | *Flat tire*, *Secure Shell*, *Bowline*: what the thing is, not how to do it |
| Wikiversity | `en.wikiversity.org/w/api.php` | As Wikibooks | "solder electronic components" → *Introduction to Electronics/Lecture Soldering*; "set up ssh keys" → *OpenSSH*; "fix a flat bicycle tire" → 0 hits |
| ArchWiki | `wiki.archlinux.org/api.php` (MediaWiki 1.46) | None published | "ssh keys" → *SSH keys* (via redirect); "suspend hibernate" → *Suspend and Hibernate* (redirect); "uncomplicated firewall" → *Ufw*. "install nvidia drivers" → 0 hits: every word must match |
| Appropedia | `www.appropedia.org/w/api.php` | None published; no `robots.txt` (404) | "bake sourdough bread" → *Making bread*; "build a solar water heater" → *Solar Water Heater, La Quinta, California*; "grow tomatoes" → #3 *Growing tomatoes* |
| MDN | No usable API. `/en-US/search-index.json` (1.5 MB, 14,738 titles) to match titles, then `<page>/index.json` for the body | None published (static files) | "center" → *Center an element*; "fetch" → *Using the Fetch API*; "lazy load" → *Lazy loading* |
| Gentoo wiki | `wiki.gentoo.org/api.php`, disallowed by `robots.txt` | – | Run before reading `robots.txt`: "suspend hibernate" → *Suspend and hibernate*; "nvidia driver" → *NVIDIA/nvidia-drivers* (Italian); "firewall" → *Iptables* |
| iFixit | `/api/2.0/search/{q}?filter=guide` | Free key: 1,000 content calls and 10,000 other calls a month, hard limit [6] | "replace iphone 12 battery" → *iPhone 12 Battery Replacement*; "replace laptop keyboard" → *Lenovo X1 Carbon Laptop Keyboard Replacement*; "fix leaking faucet" → 0 hits |
| Stack Exchange API | `/2.3/search/advanced` | 300 a day without a key (279 left after these) | diy "unclog a drain" → *Why is it unwise to use a Drain King to unclog a toilet?*; superuser "set up ssh keys" → *How to set up SSH key forwarding with gpg-agent?*; bicycles "fix a flat tire" → *fixing flat tire* |
| wikiHow, Instructables, Debian, Ubuntu, OpenStax, LibreTexts | Not run | – | Terms or `robots.txt` forbid it, or there is no search API |

## The Stack Exchange data dump

**The dump terms are narrower than the AUP, but the dump still isn't a source.**

- **Terms.** The download checkbox bans only LLM training: "for my own use and for projects that do not include training a large language model (LLM)" [9]. It doesn't repeat the AUP's ban on "indexing" or "machine learning" [9]. The AUP bans *automated* collection from "any Network website or Service"; a dump downloaded by hand isn't that `[INFERENCE]`. So keeping and embedding it locally (bge-m3, no training) looks allowed. The `license.txt` inside each file says CC BY-SA [9].
- **Why it fails.** A login and a manual checkbox, per site, every quarter: no scripted access. No search API: it is a bulk import of whole sites, and Knowseek's discovery searches a source per query. "For my own use" means `share: pointer` at most.
- **Mirrors.** Volunteers re-upload each dump to archive.org without a login, which CC BY-SA allows, but Stack Overflow asks people not to [9].
- **If wanted later:** a separate bulk-import feature for one owner's instance (for example `diy` or `superuser`), with its own plan. Not this issue.

## Unverified

- Whether embedding with a pretrained model counts as iFixit's "training" (I read it as no) or whether a free "Community" key counts as "production" use, which the pricing page says needs a paid plan [6].
- Whether Autodesk's AUP covers Instructables; the Instructables terms page is dated 2013-06-05 [8].
- The license of documentation.ubuntu.com: no notice on the pages read; I applied the ubuntu.com site terms `[INFERENCE]`.
- Rate limits for ArchWiki, Appropedia and MDN's static files: none published, none tested.
- The Stack Exchange dump: not downloaded (needs an account), so neither `license.txt` nor the checkbox was seen first hand; both are quoted from Stack Exchange's own help page and staff and user posts on Meta [9].
- LibreTexts' AI policy page rendered nothing that mentions scraping or training.

## Sources (read 2026-11-06)

1. Wikimedia: the [Terms of Use and rate limits as quoted in the storage note](storage-and-licenses.md#sources-read-2026-11-06) ([1]–[3] there): "Reusers may comply with either license or both."; "limit the number of concurrent requests to 3 or fewer."; "Rate limits apply across all sites and platforms". Wikibooks and Wikiversity `siteinfo` `rightsinfo`: "Creative Commons Attribution-Share Alike 4.0"; Wikibooks 99,158 and Wikiversity 37,579 content pages.
2. [Appropedia terms of use](https://www.appropedia.org/Appropedia:Terms_of_use): "Unless stated otherwise, you are releasing all content on Appropedia under the CC-BY-SA 4.0 International license." Each page shows its own license under "Page data". `https://www.appropedia.org/robots.txt` answers 404. 24,943 content pages.
3. [ArchWiki footer](https://wiki.archlinux.org/title/SSH_keys): "Content is available under GNU Free Documentation License 1.3 or later unless otherwise noted." The [Arch Linux Terms of Service](https://terms.archlinux.org/docs/terms-of-service/) have no clause on robots, scraping or machine learning (searched). [`robots.txt`](https://wiki.archlinux.org/robots.txt) disallows `/index.php?`, `/skins/` and `File:`, `Image:`, `MediaWiki:`, `Special:` and `Template:` pages only. 4,464 content pages.
4. [Gentoo Wiki:Copyrights](https://wiki.gentoo.org/wiki/Gentoo_Wiki:Copyrights): "published under the terms of the Creative Commons Attribution-ShareAlike 4.0 International license". [`robots.txt`](https://wiki.gentoo.org/robots.txt), `User-agent: *`: "Disallow: /api.php", "Disallow: /wiki/Special:Search".
5. [MDN attribution and licensing](https://developer.mozilla.org/en-US/docs/MDN/Writing_guidelines/Attrib_copyright_license): "available under the terms of the Creative Commons Attribution-ShareAlike license (CC-BY-SA), v2.5 or any later version"; "attribution is given to the material as well as to "Mozilla Contributors"". [`robots.txt`](https://developer.mozilla.org/robots.txt): "Disallow: /api/". [Mozilla website terms](https://www.mozilla.org/en-US/about/legal/terms/mozilla/): no clause on robots or scraping (searched).
6. iFixit. [Terms of Use](https://www.ifixit.com/Info/Terms_of_Service) (updated 2026-04-08): "reproducing, copying or distributing any Content … for any other purpose, including training a machine learning or AI model, is strictly prohibited without the express prior written permission of iFixit." [Licensing](https://www.ifixit.com/Info/Licensing): "All iFixit content is licensed under the Creative Commons BY-NC-SA 3.0 license." [API docs](https://www.ifixit.com/api/2.0/doc): "This API is free for non-commercial use"; "Starting January 1, 2027, we will require an API key for all API requests". [Pricing](https://www.ifixit.com/Developers/Pricing): "Community keys stop at 1,000 content calls or 10,000 other calls"; "You must include parts purchase links with any repair guide or schematics that you display."; "You must switch to paid plans for anything in production, whether for internal or external use." [`robots.txt`](https://www.ifixit.com/robots.txt): "Content-Signal: search=yes, ai-input=yes, ai-train=no", "Disallow: /api/*", with `Allow` only for `/api/2.0/categories*`, `guides*`, `wikis*` and `reviews/*`.
7. wikiHow. [Terms of Use](https://www.wikihow.com/wikiHow:Terms-of-Use): "(x) using or scraping the content or data on the Service to train machine learning or to use in artificial intelligence models without express written permission from wikiHow"; text is licensed to users "exclusively within the Service". [Creative Commons page](https://www.wikihow.com/wikiHow:Creative-Commons): "Effective March 24, 2025, user content will no longer be licensed under the Creative Commons License". [`robots.txt`](https://www.wikihow.com/robots.txt): "strictly prohibited from using our content for the purposes of training or retrieval for AI models".
8. Instructables. [Terms of Service](https://www.autodesk.com/company/legal-notices-trademarks/terms-of-service-autodesk360-web-services/instructables-terms-of-service-june-5-2013) (last updated 2013-06-05): "use any robot, spider, or other system, device or mechanism to access the Service likely to disrupt or disable or destroy the Service". [Autodesk Acceptable Use Policy](https://www.autodesk.com/company/terms-of-use/en/acceptable-use) (2025-12-08): "Collect Autodesk or third-party content or information, from or within an Offering, using automated means (such as any robot, spider, site search/retrieval application, or other device to retrieve, index, "scrape," or "data mine")". No public search API found. Licenses are chosen per project (CC BY, CC BY-NC-SA and others seen).
9. Stack Exchange. [Data dump help](https://meta.stackexchange.com/help/data-dumps): "Check the box affirming that you do not intend to use the file for LLM training". [Announcement](https://meta.stackexchange.com/questions/401324/announcing-a-change-to-the-data-dump-process), final checkbox text: "I understand that this file is being provided to me for my own use and for projects that do not include training a large language model (LLM)"; "We would really rather users do not upload the file to archive.org or similar data pile sites." [Dump updates](https://meta.stackexchange.com/questions/402501/data-dumps-updates-and-bug-fixes): "A license.txt is present inside each .7z", quoted there as "All content contributed to Stack Exchange sites is licensed under the Creative Commons CC BY-SA license." [Acceptable Use Policy](https://stackoverflow.com/legal/acceptable-use-policy): "any automated system … to access any Network website or Service, or to collect, gather, or copy any text … for the purpose of: … indexing, benchmarking, or improving any generative AI, chatbot, large language, or machine learning tool".
10. [Debian wiki licensing terms](https://wiki.debian.org/DebianWiki/LicencingTerms): "it's unclear which license apply to the content of this site". [`robots.txt`](https://wiki.debian.org/robots.txt): "Crawl-delay: 20".
11. Ubuntu. [`wiki.ubuntu.com/robots.txt`](https://wiki.ubuntu.com/robots.txt): "Disallow: /w/" (the API lives under `/w/`); its `siteinfo`: 73 articles. [ubuntu.com terms](https://ubuntu.com/legal/terms): "download and print pages from this website for personal, education and non-commercial use only". `help.ubuntu.com` answered 503.
12. [OpenStax terms](https://openstax.org/tos): "Each individual work in the Service is offered for license to you by the author of that work on the terms and conditions set forth in the Creative Commons license associated with that individual work"; footer: "textbooks on this site are licensed under a Creative Commons Attribution-NonCommerical-ShareAlike 4.0 International License".
13. [LibreTexts terms](https://libretexts.org/terms-conditions): "Content can be downloaded or copied consistent with the licensing of the material." [`robots.txt`](https://eng.libretexts.org/robots.txt): "Disallow: /@*", "Disallow: /Special:*", "Crawl-delay: 5".
