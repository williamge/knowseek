import { useEffect, useState } from "react";
import { api } from "../api";
import { formatBytes, shortDate } from "../lib/format";
import type { Stats } from "../types";

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

function message(error: unknown): string {
  return error instanceof Error ? error.message : "Something went wrong.";
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
  const { searches, pages, hit_share: share } = stats;

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

      <h2>Disk</h2>
      <p>{formatBytes(stats.disk_bytes)} (the database file).</p>

      <h2>Network</h2>
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
