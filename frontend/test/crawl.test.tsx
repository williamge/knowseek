import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it } from "vitest";
import { App } from "../src/App";
import { crawl, crawlEntry, document as doc, mockApi } from "./fixtures";

function openCrawl() {
  window.history.replaceState(null, "", "/crawl");
}

describe("crawl page", () => {
  it.each([
    [
      "preview",
      "Preview: Knowseek scores the links of the pages your searches found, and fetches nothing. Set CRAWL_MODE=on to let it fetch.",
    ],
    ["on", "3 of 100 pages fetched today. One page a minute while you are not searching."],
    ["off", "The background crawl is off."],
  ] as const)("says what mode %s does", async (mode, text) => {
    mockApi({ "GET /crawl": () => crawl({ mode, fetched_today: 3 }) });
    openCrawl();
    render(<App />);

    expect(await screen.findByRole("heading", { name: "Crawl" })).toBeInTheDocument();
    expect(await screen.findByText(text)).toBeInTheDocument();
  });

  it("lists the next links with their scores", async () => {
    mockApi({
      "GET /crawl": () =>
        crawl({
          next: [
            crawlEntry({
              gap: 0.1,
              shared: 0.07,
              shared_count: 3,
              interest: 0.8,
              novelty: 0.5,
              score: 0.97,
            }),
            crawlEntry({
              title: "Chains",
              description: null,
              url: "https://example.org/chains",
              source: { document_id: "doc-2", title: null, url: null, queries: [] },
            }),
          ],
        }),
    });
    openCrawl();
    render(<App />);

    expect(await screen.findByRole("heading", { name: "Next" })).toBeInTheDocument();
    const link = screen.getByRole("link", { name: "Bicycle tires" });
    expect(link).toHaveAttribute("href", "https://example.org/tires");
    expect(link).toHaveAttribute("target", "_blank");
    expect(link).toHaveAttribute("rel", "noreferrer noopener");
    expect(screen.getByText("How to pick tires for a road bike.")).toBeInTheDocument();

    const rows = screen.getAllByRole("row");
    expect(
      within(rows[1])
        .getAllByRole("cell")
        .map((cell) => cell.textContent),
    ).toEqual([
      "Bicycle tiresHow to pick tires for a road bike.",
      "Bicyclefrom your search “road bike”",
      "0.80",
      "0.50",
      "+0.10",
      "+0.07 (3 pages)",
      "0.97",
    ]);
    const plain = within(rows[2]).getAllByRole("cell");
    expect(plain[1]).toHaveTextContent("(page removed)");
    expect(plain[4]).toHaveTextContent("–");
    expect(plain[5]).toHaveTextContent("–");
  });

  it("links the source page to the reader and the candidate to its own page", async () => {
    mockApi({ "GET /crawl": () => crawl() });
    openCrawl();
    render(<App />);

    const source = await screen.findByRole("link", { name: "Bicycle" });
    expect(source).toHaveAttribute("href", "/crawl?doc=doc-1");
    expect(source).not.toHaveAttribute("target");
    expect(screen.getByRole("link", { name: "Bicycle tires" })).toHaveAttribute(
      "href",
      "https://example.org/tires",
    );
  });

  it("opens the source page in the reader over the crawl page and closes back to it", async () => {
    mockApi({
      "GET /crawl": () => crawl(),
      "GET /documents/doc-1": () => doc({ id: "doc-1", title: "Bicycle" }),
    });
    openCrawl();
    render(<App />);

    await userEvent.click(await screen.findByRole("link", { name: "Bicycle" }));
    const dialog = await screen.findByRole("dialog");
    expect(dialog).toHaveTextContent("Second paragraph");
    expect(window.location.pathname).toBe("/crawl");
    expect(window.location.search).toBe("?doc=doc-1");
    expect(screen.getByRole("heading", { name: "Crawl" })).toBeInTheDocument();

    await userEvent.keyboard("{Escape}");
    await waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument());
    await waitFor(() => expect(window.location.search).toBe(""));
    expect(window.location.pathname).toBe("/crawl");
    expect(screen.getByRole("heading", { name: "Crawl" })).toBeInTheDocument();
  });

  it("opens the reader when the page is loaded with ?doc=", async () => {
    mockApi({
      "GET /crawl": () => crawl(),
      "GET /documents/doc-1": () => doc({ id: "doc-1", title: "Bicycle" }),
    });
    window.history.replaceState(null, "", "/crawl?doc=doc-1");
    render(<App />);

    expect(await screen.findByRole("dialog")).toHaveTextContent("Second paragraph");
    expect(await screen.findByRole("heading", { name: "Next" })).toBeInTheDocument();

    await userEvent.keyboard("{Escape}");
    await waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument());
    expect(window.location.pathname + window.location.search).toBe("/crawl");
  });

  it("lists the searches that showed the source page, a few at most", async () => {
    mockApi({
      "GET /crawl": () =>
        crawl({
          next: [
            crawlEntry({
              source: {
                document_id: "doc-1",
                title: "Bicycle",
                url: null,
                queries: ["road bike", "bike tires", "chain wax", "fixie", "gravel"],
              },
            }),
          ],
        }),
    });
    openCrawl();
    render(<App />);

    expect(
      await screen.findByText(
        "from your searches “road bike”, “bike tires”, “chain wax” and 2 more",
      ),
    ).toBeInTheDocument();
  });

  it("shows an empty list", async () => {
    mockApi({ "GET /crawl": () => crawl({ next: [] }) });
    openCrawl();
    render(<App />);

    expect(
      await screen.findByText(
        "No candidates yet. They appear after you search and the instance has been idle for a while.",
      ),
    ).toBeInTheDocument();
    expect(screen.queryByRole("table")).not.toBeInTheDocument();
  });

  it("lists the fetched pages with when they were fetched and whether a search showed them", async () => {
    mockApi({
      "GET /crawl": () =>
        crawl({
          next: [],
          fetched: [
            crawlEntry({
              title: "Desem",
              description: "Sourdough starter",
              url: "https://en.wikipedia.org/wiki/Desem",
              document_id: "bg-1",
              fetched_at: "2026-11-10T09:30:00Z",
              stored_bytes: 120_000,
              hit: true,
              score: 0.69,
            }),
            crawlEntry({
              title: "Poolish",
              description: null,
              url: "https://en.wikipedia.org/wiki/Poolish",
              source: { document_id: "doc-2", title: null, url: null, queries: [] },
              document_id: "bg-2",
              fetched_at: "2026-11-09T09:30:00Z",
              hit: false,
            }),
          ],
        }),
    });
    openCrawl();
    render(<App />);

    expect(await screen.findByRole("heading", { name: "Fetched" })).toBeInTheDocument();
    expect(screen.getByText("No candidates yet.", { exact: false })).toBeInTheDocument();
    const rows = screen.getAllByRole("row");
    expect(
      within(rows[0])
        .getAllByRole("columnheader")
        .map((cell) => cell.textContent),
    ).toEqual([
      "Page",
      "Linked from",
      "Interest",
      "Novelty",
      "Gap",
      "Shared",
      "Score",
      "Fetched",
      "In your results",
    ]);
    expect(
      within(rows[1])
        .getAllByRole("cell")
        .map((cell) => cell.textContent),
    ).toEqual([
      "DesemSourdough starter",
      "Bicyclefrom your search “road bike”",
      "0.80",
      "0.50",
      "–",
      "–",
      "0.69",
      "Nov 10",
      "Yes",
    ]);
    const second = within(rows[2]).getAllByRole("cell");
    expect(second[1]).toHaveTextContent("(page removed)");
    expect(second[7]).toHaveTextContent("Nov 9");
    expect(second[8]).toHaveTextContent("No");
    expect(screen.getByRole("link", { name: "Desem" })).toHaveAttribute(
      "href",
      "https://en.wikipedia.org/wiki/Desem",
    );
  });

  it("links the source page of a fetched page to the reader", async () => {
    mockApi({
      "GET /crawl": () =>
        crawl({
          next: [],
          fetched: [crawlEntry({ document_id: "bg-1", fetched_at: "2026-11-10T09:30:00Z" })],
        }),
      "GET /documents/doc-1": () => doc({ id: "doc-1", title: "Bicycle" }),
    });
    openCrawl();
    render(<App />);

    await userEvent.click(await screen.findByRole("link", { name: "Bicycle" }));

    expect(await screen.findByRole("dialog")).toHaveTextContent("Second paragraph");
    expect(window.location.search).toBe("?doc=doc-1");
  });

  it("says nothing was fetched yet", async () => {
    mockApi({ "GET /crawl": () => crawl({ mode: "on", fetched: [] }) });
    openCrawl();
    render(<App />);

    expect(await screen.findByRole("heading", { name: "Fetched" })).toBeInTheDocument();
    expect(screen.getByText("Nothing fetched yet.")).toBeInTheDocument();
  });

  it("shows an alert when the crawl does not load", async () => {
    mockApi({
      "GET /crawl": () =>
        new Response(JSON.stringify({ errors: { detail: "boom" } }), { status: 500 }),
    });
    openCrawl();
    render(<App />);

    expect(await screen.findByRole("alert")).toHaveTextContent("Could not load the crawl.");
  });

  it("opens from the site navigation", async () => {
    window.history.replaceState(null, "", "/");
    mockApi({ "GET /documents": () => [], "GET /crawl": () => crawl() });
    render(<App />);

    const nav = screen.getByRole("navigation", { name: "More pages" });
    await userEvent.click(within(nav).getByRole("link", { name: "Crawl" }));

    expect(await screen.findByRole("heading", { name: "Crawl" })).toBeInTheDocument();
    expect(window.location.pathname).toBe("/crawl");
  });
});
