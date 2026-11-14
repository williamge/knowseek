import { useEffect, useState } from "react";
import { api } from "../api";
import { shortDate } from "../lib/format";
import { routeToUrl } from "../router";
import type { Crawl, CrawlEntry } from "../types";

function status(crawl: Crawl): string {
  switch (crawl.mode) {
    case "preview":
      return "Preview: Knowseek scores the links of the pages your searches found, and fetches nothing. Set CRAWL_MODE=on to let it fetch.";
    case "on":
      return `${crawl.fetched_today.toLocaleString("en")} of ${crawl.pages_per_day.toLocaleString("en")} pages fetched today. One page a minute while you are not searching.`;
    case "off":
      return "The background crawl is off.";
  }
}

const PAUSED: Record<NonNullable<Crawl["paused"]>, string> = {
  disk: "Paused: the disk budget is nearly used up. See Stats.",
  network: "Paused: today's network budget is nearly used up. It starts again at 00:00 UTC.",
  free_disk: "Paused: this disk is nearly full, or its free space cannot be read. See Stats.",
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

/**
 * Scored links with what makes up each score: the ones the background crawl
 * would fetch next, or (with `fetched`) the pages it fetched, which also show
 * when and whether a search of yours showed them.
 */
function EntryTable({
  entries,
  fetched = false,
  onOpenDocument,
}: {
  entries: CrawlEntry[];
  fetched?: boolean;
  onOpenDocument: (id: string) => void;
}) {
  return (
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
          {fetched && <th>Fetched</th>}
          {fetched && <th>In your results</th>}
        </tr>
      </thead>
      <tbody>
        {entries.map((entry) => (
          <tr key={`${entry.source.document_id}-${entry.url}`}>
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
            {fetched && <td>{entry.fetched_at ? shortDate(entry.fetched_at) : "–"}</td>}
            {fetched && <td>{entry.hit ? "Yes" : "No"}</td>}
          </tr>
        ))}
      </tbody>
    </table>
  );
}

/** What the background crawl would fetch next, and what it fetched, with what makes up each score. */
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
          <p className="muted">{status(crawl)}</p>
          {crawl.paused && (
            <div className="notice">
              <p>{PAUSED[crawl.paused]}</p>
            </div>
          )}

          <h2>Next</h2>
          {crawl.next.length === 0 ? (
            <div className="notice">
              No candidates yet. They appear after you search and the instance has been idle for a
              while.
            </div>
          ) : (
            <EntryTable entries={crawl.next} onOpenDocument={onOpenDocument} />
          )}

          <h2>Fetched</h2>
          {crawl.fetched.length === 0 ? (
            <p className="muted">Nothing fetched yet.</p>
          ) : (
            <EntryTable entries={crawl.fetched} fetched onOpenDocument={onOpenDocument} />
          )}
        </>
      )}
    </section>
  );
}
