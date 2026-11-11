import { useEffect, useState } from "react";
import { api } from "../api";
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

/** The links the background crawl would fetch next, with what makes up each score. */
export function CrawlPage() {
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
                    <td>{entry.source.title ?? "(page removed)"}</td>
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
