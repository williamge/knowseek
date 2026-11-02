import { clockTime } from "../lib/format";
import type { CompanyFacts as CompanyFactsData, CompanyFiling } from "../types";

/** "Sep 3, 2026" from "2026-09-03". Calendar dates have no time zone, so read them as UTC. */
function date(iso: string | null | undefined): string {
  if (!iso || Number.isNaN(new Date(iso).getTime())) return "date unknown";
  return new Date(iso).toLocaleDateString("en", {
    month: "short",
    day: "numeric",
    year: "numeric",
    timeZone: "UTC",
  });
}

/** "January 31" from a month and a day. */
function monthDay(month: number, day: number): string {
  return new Date(Date.UTC(2000, month - 1, day)).toLocaleDateString("en", {
    month: "long",
    day: "numeric",
    timeZone: "UTC",
  });
}

/** "24.1 billion" */
function count(value: number): string {
  return value.toLocaleString("en", {
    notation: "compact",
    compactDisplay: "long",
    maximumFractionDigits: 2,
  });
}

function filingDetail(filing: CompanyFiling): string {
  if (filing.items.length > 0) {
    return `item${filing.items.length > 1 ? "s" : ""} ${filing.items.join(", ")}`;
  }
  return filing.report_date ? `period ending ${date(filing.report_date)}` : "";
}

/** What the SEC knows about a public company: who it is, its shares, its latest filings. */
export function CompanyBody({ title, facts }: { title: string; facts: CompanyFactsData }) {
  const { listings, shares_outstanding: shares, fiscal_year_end: year } = facts;

  return (
    <>
      <header className="fact-card__head">
        <h2 className="fact-card__title">{title}</h2>
        {listings.map(({ ticker, exchange }) => (
          <span key={`${exchange ?? ""}:${ticker}`} className="fact-card__league">
            {exchange ? `${exchange}: ` : ""}
            {ticker}
          </span>
        ))}
      </header>
      {facts.legal_name !== title && (
        <p className="fact-card__muted company__legal">Registered as {facts.legal_name}</p>
      )}

      <dl className="fact-card__facts">
        {facts.industry && (
          <div className="fact-card__row">
            <dt>Industry</dt>
            <dd>{facts.industry}</dd>
          </div>
        )}

        {year && (
          <div className="fact-card__row">
            <dt>Fiscal year ends</dt>
            <dd>{monthDay(year.month, year.day)}</dd>
          </div>
        )}

        {facts.category && (
          <div className="fact-card__row">
            <dt>Filer category</dt>
            <dd>{facts.category}</dd>
          </div>
        )}

        {shares && (
          <div className="fact-card__row">
            <dt>Shares outstanding</dt>
            <dd>
              <strong title={shares.value.toLocaleString("en")}>{count(shares.value)}</strong>
              <span className="fact-card__muted"> · as of {date(shares.as_of)}</span>
            </dd>
          </div>
        )}

        {facts.filings.length > 0 && (
          <div className="fact-card__row">
            <dt>Recent filings</dt>
            <dd>
              <ul className="company__filings">
                {facts.filings.map((filing) => (
                  <li key={filing.url}>
                    <a href={filing.url} target="_blank" rel="noopener noreferrer">
                      {filing.form}
                    </a>{" "}
                    <span className="fact-card__muted">
                      · filed {date(filing.filed)}
                      {filingDetail(filing) && ` · ${filingDetail(filing)}`}
                    </span>
                  </li>
                ))}
              </ul>
            </dd>
          </div>
        )}
      </dl>
    </>
  );
}

/** The footer of the card: the time the card was fetched and the credit to the SEC. */
export function CompanyCredit({ facts, asOf }: { facts: CompanyFactsData; asOf: string | null }) {
  return (
    <>
      <span>
        Source:{" "}
        <a href={facts.source_url} target="_blank" rel="noopener noreferrer">
          {facts.source}
        </a>
      </span>
      {asOf && (
        <span>
          as of <time dateTime={asOf}>{clockTime(asOf)}</time>
        </span>
      )}
    </>
  );
}
