import { useEffect, useState } from "react";
import { api } from "../api";
import { routeToUrl } from "../router";
import type { Crawl, CrawlEntry, CrawlMode } from "../types";

const STATUS: Record<CrawlMode, string> = {
  preview:
    "Preview: Knowseek scores the links of the pages your searches found, and fetches nothing. Set CRAWL_MODE=on to let it fetch.",
  on: "Fetching is not built yet: until it is, the crawl only scores links, like preview.",
  off: "The background crawl is off.",
};

const score = (value: number) => value.toFixed(2);

/** A bonus as "+0.10", or "–" when there is none. */
const bonus = (value: number) => (value === 0 ? "–" : `+${value.toFixed(2)}`);

function shared(entry: CrawlEntry): string {
  if (entry.shared === 0) return "–";
  const text = bonus(entry.shared);
  return entry.shared_count > 1 ? `${text} (${entry.shared_count} pages)` : text;
}

/** How many of a source page's searches are listed; the rest is a count. */
const SHOWN_QUERIES = 3;

/** The searches that showed a source page, as a short line. */
function fromSearches(queries: string[]): string | null {
  if (queries.length === 0) return null;
  const shown = queries.slice(0, SHOWN_QUERIES).map((query) => `“${query}”`);
  const more = queries.length - shown.length;
  const list = shown.join(", ") + (more > 0 ? ` and ${more} more` : "");
  return `from your ${queries.length === 1 ? "search" : "searches"} ${list}`;
}

/** The links the background crawl would fetch next, with what makes up each score. */
export function CrawlPage({ onOpenDocument }: { onOpenDocument: (id: string) => void }) {
  const [crawl, setCrawl] = useState<Crawl | null>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    const controller = new AbortController();
    api.getCrawl(controller.signal).then(setCrawl, () => {
      if (!controller.signal.aborted) setFailed(true);
    });
    return () => controller.abort();
  }, []);

  return (
    <section className="subpage">
      <h1>Crawl</h1>

      {failed ? (
        <div className="notice notice--error" role="alert">
          Could not load the crawl.
        </div>
      ) : !crawl ? (
        <p className="muted">Loading…</p>
      ) : (
        <>
          <p className="muted">{STATUS[crawl.mode]}</p>

          <h2>Next</h2>
          {crawl.next.length === 0 ? (
            <div className="notice">
              No candidates yet. They appear after you search and the instance has been idle for a
              while.
            </div>
          ) : (
            <table className="data-table">
              <thead>
                <tr>
                  <th>Page</th>
                  <th>Linked from</th>
                  <th className="num">Interest</th>
                  <th className="num">Novelty</th>
                  <th className="num">Gap</th>
                  <th className="num">Shared</th>
                  <th className="num">Score</th>
                </tr>
              </thead>
              <tbody>
                {crawl.next.map((entry) => (
                  <tr key={entry.url}>
                    <td>
                      <a href={entry.url} rel="noreferrer noopener" target="_blank">
                        {entry.title}
                      </a>
                      {entry.description && <div className="muted">{entry.description}</div>}
                    </td>
                    <td>
                      {entry.source.title === null ? (
                        "(page removed)"
                      ) : (
                        <a
                          href={routeToUrl({
                            page: "crawl",
                            query: null,
                            doc: entry.source.document_id,
                          })}
                          onClick={(event) => {
                            event.preventDefault();
                            onOpenDocument(entry.source.document_id);
                          }}
                        >
                          {entry.source.title}
                        </a>
                      )}
                      {fromSearches(entry.source.queries) && (
                        <div className="muted">{fromSearches(entry.source.queries)}</div>
                      )}
                    </td>
                    <td className="num">{score(entry.interest)}</td>
                    <td className="num">{score(entry.novelty)}</td>
                    <td className="num">{bonus(entry.gap)}</td>
                    <td className="num">{shared(entry)}</td>
                    <td className="num">{score(entry.score)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </>
      )}
    </section>
  );
}
