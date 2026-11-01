import { render, screen, within } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { FactCard } from "../src/components/FactCard";
import type { CardResponse, CompanyFacts } from "../src/types";
import { cardResponse } from "./fixtures";

const nvidiaEntity = {
  id: "Q182477",
  label: "Nvidia",
  description: "American technology company",
  kind: "company",
  wikipedia_title: "Nvidia",
};

function facts(overrides: Partial<CompanyFacts> = {}): CompanyFacts {
  return {
    source: "Twelve Data",
    symbol: "NVDA",
    exchange: "Nasdaq",
    currency: "USD",
    price: 204.64,
    previous_close: 213.66,
    change: -9.02,
    percent_change: -4.22,
    market_state: "closed",
    quote_time: "2026-10-30T20:00:00Z",
    delayed: false,
    ...overrides,
  };
}

function companyCard(
  overrides: Partial<CompanyFacts> = {},
  response: Partial<CardResponse> = {},
): CardResponse {
  return cardResponse({
    entity: nvidiaEntity,
    alternatives: [],
    card: { type: "company", title: "NVIDIA Corp", facts: facts(overrides) },
    as_of: "2026-10-31T15:42:15Z",
    ...response,
  });
}

function show(data: CardResponse) {
  render(<FactCard data={data} onSearch={() => {}} />);
  return screen.getByRole("region", { name: "Live facts: NVIDIA Corp" });
}

describe("company card", () => {
  it("shows the price, a negative change and the closed market", () => {
    const card = show(companyCard());

    expect(within(card).getByRole("heading", { name: "NVIDIA Corp" })).toBeInTheDocument();
    expect(within(card).getByText("Nasdaq: NVDA")).toBeInTheDocument();
    expect(within(card).getByText("$204.64")).toBeInTheDocument();
    expect(within(card).getByText(/−9\.02/)).toHaveClass("quote__change--down");
    expect(within(card).getByText(/\(−4\.22%\)/)).toBeInTheDocument();
    expect(within(card).getByText(/vs previous close \$213\.66/)).toBeInTheDocument();
    expect(within(card).getByText("Market closed")).toBeInTheDocument();
    expect(within(card).getByText("Twelve Data")).toBeInTheDocument();
  });

  it("shows a positive change with a plus sign and an open market", () => {
    const card = show(
      companyCard({ change: 1.11, percent_change: 0.32, price: 350.02, market_state: "open" }),
    );

    expect(within(card).getByText(/\+1\.11/)).toHaveClass("quote__change--up");
    expect(within(card).getByText(/\(\+0\.32%\)/)).toBeInTheDocument();
    expect(within(card).getByText("Market open")).toBeInTheDocument();
  });

  it("says nothing about a change of zero, and handles a missing percent", () => {
    const card = show(companyCard({ change: 0, percent_change: null }));

    const change = card.querySelector(".quote__change");
    expect(change).toHaveClass("quote__change--flat");
    expect(change?.textContent).toBe("0.00");
  });

  it("labels a delayed quote, and does not label a real-time one", () => {
    const { unmount } = render(
      <FactCard data={companyCard({ delayed: true })} onSearch={() => {}} />,
    );
    expect(screen.getByText("delayed quote")).toBeInTheDocument();
    unmount();

    render(<FactCard data={companyCard({ delayed: false })} onSearch={() => {}} />);
    expect(screen.queryByText(/delayed/i)).not.toBeInTheDocument();
  });

  it("shows the time of the quote itself, not the fetch time", () => {
    const card = show(companyCard());
    const time = card.querySelector("footer time");

    expect(time).toHaveAttribute("datetime", "2026-10-30T20:00:00Z");
    expect(card.querySelector("footer")?.textContent).toContain("quote as of");
  });

  it("names the extended-hours states", () => {
    show(companyCard({ market_state: "after_hours" }));
    expect(screen.getByText("After hours")).toBeInTheDocument();
  });

  it("still marks a stale card", () => {
    show(companyCard({}, { status: "stale" }));
    expect(screen.getByRole("status")).toHaveTextContent("may be out of date");
  });

  it("renders a price without a currency or a quote time", () => {
    const card = show(companyCard({ currency: null, quote_time: null }));

    expect(within(card).getByText("$204.64")).toBeInTheDocument();
    expect(card.querySelector("footer time")).toBeNull();
  });
});
