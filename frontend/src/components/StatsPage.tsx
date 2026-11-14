import { useEffect, useState } from "react";
import { api } from "../api";
import { formatBytes, shortDate } from "../lib/format";
import type { BudgetLine, Stats } from "../types";

/** The Coverage labels of the results page (`StatusBar.tsx`). */
const COVERAGE_COLUMNS = [
  { key: "sufficient", label: "Well covered" },
  { key: "partial", label: "Partly covered" },
  { key: "none", label: "Not covered" },
] as const;

const PAGE_ROWS = [
  { key: "search", label: "From a search" },
  { key: "background", label: "Background" },
  { key: "manual", label: "Added manually" },
] as const;

// A day is a UTC calendar day: noon UTC shows as that date in any time zone.
const dayLabel = (day: string) => shortDate(`${day}T12:00:00Z`);

const plural = (count: number, one: string, many = `${one}s`) => (count === 1 ? one : many);

function message(error: unknown): string {
  return error instanceof Error ? error.message : "Something went wrong.";
}

function BudgetBar({
  label,
  line,
  share,
  suffix = "",
}: {
  label: string;
  line: BudgetLine;
  share: number;
  suffix?: string;
}) {
  const percent =
    line.limit === 0 ? 100 : Math.min(100, Math.round((line.used / line.limit) * 100));
  return (
    <p className="budget">
      <meter
        aria-label={label}
        min={0}
        max={Math.max(line.limit, 1)}
        high={line.limit * share}
        optimum={0}
        value={Math.min(line.used, Math.max(line.limit, 1))}
      />{" "}
      {`${formatBytes(line.used)} of ${formatBytes(line.limit)}${suffix} (${percent}%)`}
    </p>
  );
}

function Notice({ text }: { text: string }) {
  return (
    <div className="notice">
      <p>{text}</p>
    </div>
  );
}

/** The numbers over the search log, the pages and the network (#96). */
export function StatsPage() {
  const [stats, setStats] = useState<Stats | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [reload, setReload] = useState(0);

  useEffect(() => {
    const controller = new AbortController();
    api.getStats(controller.signal).then(
      (loaded) => {
        setError(null);
        setStats(loaded);
      },
      (failure) => {
        if (!controller.signal.aborted) setError(message(failure));
      },
    );
    return () => controller.abort();
  }, [reload]);

  const clearSearches = async () => {
    if (!window.confirm("Delete every recorded search?")) return;
    try {
      await api.clearSearches();
      setReload((count) => count + 1);
    } catch (failure) {
      setError(message(failure));
    }
  };

  return (
    <section className="subpage">
      <h1>Stats</h1>
      {error && (
        <div className="notice notice--error" role="alert">
          <p>{error}</p>
        </div>
      )}
      {!stats && !error && <p className="muted">Loading…</p>}
      {stats && <StatsBody stats={stats} onClear={clearSearches} />}
    </section>
  );
}

function StatsBody({ stats, onClear }: { stats: Stats; onClear: () => void }) {
  const { searches, pages, hit_share: share, gain } = stats;
  const stored = formatBytes(stats.crawl.stored_bytes);

  return (
    <>
      <h2>Searches</h2>
      <p>
        {searches.total} {searches.total === 1 ? "search" : "searches"} recorded.
      </p>
      <p className="muted">
        Your searches are stored in this instance&apos;s database only, until you clear them.
      </p>
      {searches.days.length > 0 && (
        <table className="data-table">
          <thead>
            <tr>
              <th scope="col">Day</th>
              <th scope="col" className="num">
                Searches
              </th>
              {COVERAGE_COLUMNS.map(({ key, label }) => (
                <th key={key} scope="col" className="num">
                  {label}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {searches.days.map((day) => (
              <tr key={day.day}>
                <th scope="row">{dayLabel(day.day)}</th>
                <td className="num">{day.sufficient + day.partial + day.none}</td>
                {COVERAGE_COLUMNS.map(({ key }) => (
                  <td key={key} className="num">
                    {day[key]}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      )}
      <p>
        <button type="button" className="link-button" onClick={onClear}>
          Clear search history
        </button>
      </p>

      <h2>Pages</h2>
      <table className="data-table">
        <tbody>
          {PAGE_ROWS.map(({ key, label }) => (
            <tr key={key}>
              <th scope="row">{label}</th>
              <td className="num">{pages[key]}</td>
            </tr>
          ))}
        </tbody>
      </table>

      <h2>Hit share</h2>
      {share.background_pages === 0 ? (
        <p className="muted">No background pages yet.</p>
      ) : (
        <p>
          {share.hit_pages} of {share.background_pages} background pages showed up in your top
          results ({Math.round((share.hit_pages / share.background_pages) * 100)}%).
        </p>
      )}

      <h2>Gain</h2>
      {share.background_pages === 0 ? (
        <p className="muted">No background pages yet.</p>
      ) : (
        <>
          <p>
            {`${gain.pages} of ${share.background_pages} background ${plural(share.background_pages, "page")} showed up where your other pages were not enough (${Math.round((gain.pages / share.background_pages) * 100)}%).`}
          </p>
          <p>
            {`${gain.searches} of your ${gain.window_searches} ${plural(gain.window_searches, "search", "searches")} in the last 30 days ${gain.searches === 1 ? "was" : "were"} covered only thanks to background pages.`}
          </p>
          <p>
            {gain.pages === 0
              ? `No useful page yet (${stored} for ${share.background_pages} background ${plural(share.background_pages, "page")}).`
              : `Stored per useful page: ${formatBytes(Math.round(stats.crawl.stored_bytes / gain.pages))} (${stored} for ${share.background_pages} background ${plural(share.background_pages, "page")}).`}
          </p>
        </>
      )}

      <h2>Crawl</h2>
      <p>
        Mode: {stats.crawl.mode}. {stats.crawl.fetched_today.toLocaleString("en")} of{" "}
        {stats.crawl.pages_per_day.toLocaleString("en")} pages fetched today.
      </p>
      <p>
        {stats.crawl.links_read.toLocaleString("en")} links read,{" "}
        {stats.crawl.candidates.toLocaleString("en")} kept as candidates.
      </p>

      <h2>Disk</h2>
      <BudgetBar
        label="Disk budget"
        line={stats.budget.disk}
        share={stats.budget.background_share}
      />
      <p className="muted">
        Everything the database takes on disk: pages, passages, vectors, the full-text index and the
        logs.
      </p>
      {stats.budget.disk.state === "near" && (
        <Notice text="The disk budget is nearly used up: the background crawl and the link backfill are paused. Set DISK_BUDGET_MB higher to continue." />
      )}
      {stats.budget.disk.state === "full" && (
        <Notice text="The disk budget is used up: searches no longer fetch new pages. Set DISK_BUDGET_MB higher to continue." />
      )}
      {stats.budget.free_disk.bytes === null ? (
        <p className="muted">Free on this disk: unknown.</p>
      ) : (
        <p>Free on this disk: {formatBytes(stats.budget.free_disk.bytes)}.</p>
      )}
      {stats.budget.free_disk.low &&
        (stats.budget.free_disk.bytes === null ? (
          <Notice text="Free disk space cannot be read: the background crawl and the link backfill are paused." />
        ) : (
          <Notice
            text={`Less than ${formatBytes(stats.budget.free_disk.floor)} is free on this disk: the background crawl and the link backfill are paused.`}
          />
        ))}
      <p>{stats.passages.toLocaleString("en")} passages stored.</p>
      {stats.passages >= 100_000 && (
        <p className="muted">
          Search compares your query with every passage, so it gets slower as this number grows.
          From about 100,000 you may notice it.
        </p>
      )}

      <h2>Network</h2>
      <BudgetBar
        label="Network budget today"
        line={stats.budget.network}
        share={stats.budget.background_share}
        suffix=" today"
      />
      {stats.budget.network.state === "near" && (
        <Notice text="Today's network budget is nearly used up: the background crawl and the link backfill are paused until 00:00 UTC." />
      )}
      {stats.budget.network.state === "full" && (
        <Notice text="Today's network budget is used up: searches no longer fetch new pages until 00:00 UTC." />
      )}
      <p className="muted">
        Counted: everything Knowseek downloads, headers included. A day is a UTC day.
      </p>
      {stats.network.length === 0 ? (
        <p className="muted">Nothing downloaded in the last 30 days.</p>
      ) : (
        <table className="data-table">
          <thead>
            <tr>
              <th scope="col">Day</th>
              <th scope="col">Source</th>
              <th scope="col" className="num">
                Downloaded
              </th>
            </tr>
          </thead>
          <tbody>
            {stats.network.map((row) => (
              <tr key={`${row.day}-${row.source}`}>
                <td>{dayLabel(row.day)}</td>
                <td>{row.source}</td>
                <td className="num">{formatBytes(row.bytes)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </>
  );
}
