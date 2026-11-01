import { gameTime } from "../lib/format";
import type { CompanyFacts as CompanyFactsData } from "../types";

const STATES: Record<CompanyFactsData["market_state"], string> = {
  open: "Market open",
  closed: "Market closed",
  pre_market: "Pre-market",
  after_hours: "After hours",
};

function money(value: number, currency: string | null): string {
  try {
    return value.toLocaleString("en", { style: "currency", currency: currency ?? "USD" });
  } catch {
    // An unknown currency code: show the number alone.
    return value.toLocaleString("en", { minimumFractionDigits: 2 });
  }
}

function signed(value: number, digits: number): string {
  const text = Math.abs(value).toLocaleString("en", {
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  });
  if (value > 0) return `+${text}`;
  return value < 0 ? `−${text}` : text;
}

/** The price card of a public company: last price, change, market state, source. */
export function CompanyBody({ title, facts }: { title: string; facts: CompanyFactsData }) {
  const direction = facts.change > 0 ? "up" : facts.change < 0 ? "down" : "flat";
  const state = STATES[facts.market_state] ?? facts.market_state;

  return (
    <>
      <header className="fact-card__head">
        <h2 className="fact-card__title">{title}</h2>
        <span className="fact-card__league">
          {facts.exchange}: {facts.symbol}
        </span>
        <span
          className={`market-state market-state--${facts.market_state}`}
          title="Market state when the quote was taken"
        >
          {state}
        </span>
      </header>

      <div className="quote">
        <strong className="quote__price">{money(facts.price, facts.currency)}</strong>
        <span className={`quote__change quote__change--${direction}`}>
          {signed(facts.change, 2)}
          {facts.percent_change !== null && <> ({signed(facts.percent_change, 2)}%)</>}
        </span>
        <span className="fact-card__muted">
          vs previous close {money(facts.previous_close, facts.currency)}
        </span>
      </div>
    </>
  );
}

/** The source, the delayed label and the time of the quote, for the footer of the card. */
export function CompanyFoot({ facts }: { facts: CompanyFactsData }) {
  return (
    <>
      <span>{facts.source}</span>
      {facts.delayed && (
        <span className="quote__delayed" title="The source says this quote is delayed">
          delayed quote
        </span>
      )}
      {facts.quote_time && (
        <span>
          quote as of <time dateTime={facts.quote_time}>{gameTime(facts.quote_time)}</time>
        </span>
      )}
    </>
  );
}
