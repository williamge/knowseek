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
    source: "SEC EDGAR",
    source_url: "https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=0001045810",
    legal_name: "NVIDIA CORP",
    cik: "0001045810",
    listings: [{ ticker: "NVDA", exchange: "Nasdaq" }],
    industry: "Semiconductors & Related Devices",
    category: "Large accelerated filer",
    fiscal_year_end: { month: 1, day: 31 },
    shares_outstanding: { value: 24_100_000_000, as_of: "2026-08-21" },
    filings: [
      {
        form: "8-K",
        filed: "2026-09-03",
        report_date: "2026-09-02",
        items: ["8.01"],
        description: "8-K",
        url: "https://www.sec.gov/Archives/edgar/data/1045810/000104581026000078/nvda-20260902.htm",
      },
      {
        form: "10-Q",
        filed: "2026-08-26",
        report_date: "2026-07-26",
        items: [],
        description: "10-Q",
        url: "https://www.sec.gov/Archives/edgar/data/1045810/000104581026000075/nvda-20260726.htm",
      },
      {
        form: "8-K",
        filed: "2026-08-26",
        report_date: null,
        items: ["2.02", "9.01"],
        description: null,
        url: "https://www.sec.gov/Archives/edgar/data/1045810/000104581026000074/nvda-20260826.htm",
      },
    ],
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
    card: { type: "company", title: "Nvidia", facts: facts(overrides) },
    as_of: "2026-11-02T15:42:15Z",
    ...response,
  });
}

function show(data: CardResponse) {
  render(<FactCard data={data} onSearch={() => {}} />);
  return screen.getByRole("region", { name: "Live facts: Nvidia" });
}

describe("company card", () => {
  it("shows who the company is: tickers, industry, fiscal year end, category", () => {
    const card = show(companyCard());

    expect(within(card).getByRole("heading", { name: "Nvidia" })).toBeInTheDocument();
    expect(within(card).getByText("Nasdaq: NVDA")).toBeInTheDocument();
    expect(within(card).getByText("Registered as NVIDIA CORP")).toBeInTheDocument();
    expect(within(card).getByText("Semiconductors & Related Devices")).toBeInTheDocument();
    expect(within(card).getByText("January 31")).toBeInTheDocument();
    expect(within(card).getByText("Large accelerated filer")).toBeInTheDocument();
  });

  it("shows the shares outstanding with their date", () => {
    const card = show(companyCard());

    const shares = within(card).getByText("24.1 billion");
    expect(shares).toHaveAttribute("title", "24,100,000,000");
    expect(within(card).getByText(/as of Aug 21, 2026/)).toBeInTheDocument();
  });

  it("lists the filings as links that open safely, with items or the period", () => {
    const card = show(companyCard());

    const links = within(card).getAllByRole("link", { name: /^(8-K|10-Q)$/ });
    expect(links).toHaveLength(3);
    expect(links[0]).toHaveAttribute(
      "href",
      "https://www.sec.gov/Archives/edgar/data/1045810/000104581026000078/nvda-20260902.htm",
    );
    for (const link of links) {
      expect(link).toHaveAttribute("target", "_blank");
      expect(link).toHaveAttribute("rel", "noopener noreferrer");
    }

    const items = within(card).getAllByRole("listitem");
    expect(items[0]).toHaveTextContent("filed Sep 3, 2026 · item 8.01");
    expect(items[1]).toHaveTextContent("filed Aug 26, 2026 · period ending Jul 26, 2026");
    expect(items[2]).toHaveTextContent("filed Aug 26, 2026 · items 2.02, 9.01");
  });

  it("credits the SEC with a link, and shows when the card was fetched", () => {
    const card = show(companyCard());

    const credit = within(card).getByRole("link", { name: "SEC EDGAR" });
    expect(credit).toHaveAttribute("href", expect.stringContaining("https://www.sec.gov/"));
    expect(credit).toHaveAttribute("rel", "noopener noreferrer");
    expect(card.querySelector("footer time")).toHaveAttribute("datetime", "2026-11-02T15:42:15Z");
    expect(card.querySelector("footer")?.textContent).toContain("Source:");
  });

  it("shows no price and no quote wording", () => {
    const card = show(companyCard());
    expect(card.textContent).not.toMatch(/\$|delayed|market (open|closed)/i);
  });

  it("leaves out what the SEC does not give", () => {
    const card = show(
      companyCard({
        legal_name: "Nvidia",
        listings: [],
        industry: null,
        category: null,
        fiscal_year_end: null,
        shares_outstanding: null,
        filings: [],
      }),
    );

    expect(within(card).queryByText("Industry")).not.toBeInTheDocument();
    expect(within(card).queryByText("Fiscal year ends")).not.toBeInTheDocument();
    expect(within(card).queryByText("Filer category")).not.toBeInTheDocument();
    expect(within(card).queryByText("Shares outstanding")).not.toBeInTheDocument();
    expect(within(card).queryByText("Recent filings")).not.toBeInTheDocument();
    expect(within(card).queryByText(/Registered as/)).not.toBeInTheDocument();
  });

  it("shows a listing whose exchange the SEC does not name, and several listings", () => {
    const card = show(
      companyCard({
        listings: [
          { ticker: "GOOGL", exchange: "Nasdaq" },
          { ticker: "GOOGX", exchange: null },
        ],
      }),
    );

    expect(within(card).getByText("Nasdaq: GOOGL")).toBeInTheDocument();
    expect(within(card).getByText("GOOGX")).toBeInTheDocument();
  });

  it("shows a placeholder, not 1970, for a filing date that is missing or invalid", () => {
    const base = facts().filings[0];
    const card = show(
      companyCard({
        filings: [
          { ...base, filed: null as unknown as string, url: "https://www.sec.gov/a" },
          { ...base, filed: "not a date", report_date: "nope", url: "https://www.sec.gov/b" },
        ],
      }),
    );

    expect(card.textContent).not.toContain("1970");
    expect(card.textContent).not.toContain("Invalid");
    expect(within(card).getAllByText(/filed date unknown/)).toHaveLength(2);
  });

  it("still marks a stale card", () => {
    show(companyCard({}, { status: "stale" }));
    expect(screen.getByRole("status")).toHaveTextContent("may be out of date");
  });
});
