import { useEffect, useState } from "react";
import { api } from "../api";
import { shortDate } from "../lib/format";
import type { BlockedLinks } from "../types";

/** The longest example link shown; the rest is cut with an ellipsis. */
const EXAMPLE_CHARS = 60;

function cut(text: string): string {
  return text.length > EXAMPLE_CHARS ? `${text.slice(0, EXAMPLE_CHARS)}…` : text;
}

function plural(count: number, one: string, many: string): string {
  return `${count.toLocaleString("en")} ${count === 1 ? one : many}`;
}

/** Everything a crawler may not fetch from: the links the indexed pages point to, by domain (#88). */
export function BlockedLinksPage() {
  const [log, setLog] = useState<BlockedLinks | null>(null);
  const [failed, setFailed] = useState(false);
  const [scanning, setScanning] = useState(false);
  const [started, setStarted] = useState<number | null>(null);
  const [scanFailed, setScanFailed] = useState(false);

  useEffect(() => {
    const controller = new AbortController();
    api.listBlockedLinks(controller.signal).then(setLog, () => {
      if (!controller.signal.aborted) setFailed(true);
    });
    return () => controller.abort();
  }, []);

  const scan = () => {
    setScanning(true);
    setScanFailed(false);
    api.backfillBlockedLinks().then(
      (result) => {
        setStarted(result.enqueued);
        setScanning(false);
      },
      () => {
        setScanFailed(true);
        setScanning(false);
      },
    );
  };

  return (
    <section className="subpage">
      <h1>Blocked links</h1>

      {failed ? (
        <div className="notice notice--error" role="alert">
          Could not load the blocked links.
        </div>
      ) : !log ? (
        <p className="muted">Loading…</p>
      ) : (
        <>
          <p className="muted">
            Knowseek fetches only from {log.allowed_hosts.join(" and ")}. Links to other sites are
            logged here, not fetched.
          </p>
          {log.domains.length === 0 ? (
            <div className="notice">
              No blocked links yet. Links are logged when a page is indexed.
            </div>
          ) : (
            <>
              <p className="muted">
                {plural(log.total_links, "link", "links")} to{" "}
                {plural(log.total_domains, "site", "sites")}.
                {log.domains.length < log.total_domains &&
                  ` Showing the ${log.domains.length} sites most pages link to.`}
              </p>
              <table className="data-table">
                <thead>
                  <tr>
                    <th>Site</th>
                    <th className="num">Links</th>
                    <th className="num">Pages</th>
                    <th className="num">Times seen</th>
                    <th>First seen</th>
                    <th>Example</th>
                  </tr>
                </thead>
                <tbody>
                  {log.domains.map((domain) => (
                    <tr key={domain.host}>
                      <td>{domain.host}</td>
                      <td className="num">{domain.links}</td>
                      <td className="num">{domain.pages}</td>
                      <td className="num">{domain.times_seen}</td>
                      <td>{shortDate(domain.first_seen_at)}</td>
                      <td>
                        <a href={domain.example_url} rel="noreferrer noopener" target="_blank">
                          {cut(domain.example_url)}
                        </a>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </>
          )}

          <p>
            <button type="button" className="link-button" disabled={scanning} onClick={scan}>
              Scan pages already indexed
            </button>
          </p>
          {started !== null && (
            <p className="muted" role="status">
              Scanning {plural(started, "page", "pages")} in the background. Reload this page in a
              minute.
            </p>
          )}
          {scanFailed && (
            <p className="error-text" role="alert">
              Could not start the scan.
            </p>
          )}
        </>
      )}
    </section>
  );
}
