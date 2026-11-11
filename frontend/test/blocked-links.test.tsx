import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it } from "vitest";
import { App } from "../src/App";
import { blockedLinks, mockApi } from "./fixtures";

function openBlockedLinks() {
  window.history.replaceState(null, "", "/blocked-links");
}

describe("blocked links page", () => {
  it("shows the log by domain and the allowed hosts", async () => {
    mockApi({ "GET /blocked-links": () => blockedLinks() });
    openBlockedLinks();
    render(<App />);

    expect(await screen.findByRole("heading", { name: "Blocked links" })).toBeInTheDocument();
    expect(
      screen.getByText(
        "Knowseek fetches only from en.wikipedia.org and en.wikibooks.org. Links to other sites are logged here, not fetched.",
      ),
    ).toBeInTheDocument();
    expect(screen.getByText("5 links to 2 sites.")).toBeInTheDocument();

    const rows = screen.getAllByRole("row");
    const archive = within(rows[1]).getAllByRole("cell");
    expect(archive.map((cell) => cell.textContent?.slice(0, 20))).toEqual([
      "web.archive.org",
      "3",
      "2",
      "4",
      "Nov 10, 2020",
      "https://web.archive.org/web/2019/http://www.sheldonbrown.com/tires.html?a-very-long-query=1".slice(
        0,
        20,
      ),
    ]);
    expect(within(rows[2]).getByText("sheldonbrown.com")).toBeInTheDocument();
  });

  it("cuts the example link to 60 characters and opens it in a new tab", async () => {
    mockApi({ "GET /blocked-links": () => blockedLinks() });
    openBlockedLinks();
    render(<App />);

    const link = await screen.findByRole("link", { name: /^https:\/\/web\.archive\.org/ });
    expect(link.textContent).toHaveLength(61);
    expect(link.textContent?.endsWith("…")).toBe(true);
    expect(link).toHaveAttribute(
      "href",
      "https://web.archive.org/web/2019/http://www.sheldonbrown.com/tires.html?a-very-long-query=1",
    );
    expect(link).toHaveAttribute("target", "_blank");
    expect(link).toHaveAttribute("rel", "noreferrer noopener");
  });

  it("says when the list is cut", async () => {
    mockApi({ "GET /blocked-links": () => blockedLinks({ total_domains: 300, total_links: 900 }) });
    openBlockedLinks();
    render(<App />);

    expect(
      await screen.findByText("900 links to 300 sites. Showing the 2 sites most pages link to."),
    ).toBeInTheDocument();
  });

  it("shows an empty log", async () => {
    mockApi({
      "GET /blocked-links": () => blockedLinks({ domains: [], total_domains: 0, total_links: 0 }),
    });
    openBlockedLinks();
    render(<App />);

    expect(
      await screen.findByText("No blocked links yet. Links are logged when a page is indexed."),
    ).toBeInTheDocument();
    expect(screen.queryByRole("table")).not.toBeInTheDocument();
  });

  it("shows an alert when the log does not load", async () => {
    mockApi({
      "GET /blocked-links": () =>
        new Response(JSON.stringify({ errors: { detail: "boom" } }), { status: 500 }),
    });
    openBlockedLinks();
    render(<App />);

    expect(await screen.findByRole("alert")).toHaveTextContent("Could not load the blocked links.");
  });

  it("starts the backfill and says how many pages it scans", async () => {
    const { calls } = mockApi({
      "GET /blocked-links": () => blockedLinks(),
      "POST /blocked-links/backfill": () => ({ enqueued: 14 }),
    });
    openBlockedLinks();
    render(<App />);

    await userEvent.click(
      await screen.findByRole("button", { name: "Scan pages already indexed" }),
    );

    expect(await screen.findByRole("status")).toHaveTextContent(
      "Scanning 14 pages in the background. Reload this page in a minute.",
    );
    expect(calls.filter((call) => call.key === "POST /blocked-links/backfill")).toHaveLength(1);
  });

  it("shows an alert when the backfill does not start", async () => {
    mockApi({
      "GET /blocked-links": () => blockedLinks(),
      "POST /blocked-links/backfill": () =>
        new Response(JSON.stringify({ errors: { detail: "boom" } }), { status: 500 }),
    });
    openBlockedLinks();
    render(<App />);

    await userEvent.click(
      await screen.findByRole("button", { name: "Scan pages already indexed" }),
    );

    expect(await screen.findByRole("alert")).toHaveTextContent("Could not start the scan.");
  });
});

describe("site navigation", () => {
  it("opens the page from the home page, and the wordmark returns home", async () => {
    mockApi({ "GET /documents": () => [], "GET /blocked-links": () => blockedLinks() });
    render(<App />);

    const nav = screen.getByRole("navigation", { name: "More pages" });
    await userEvent.click(within(nav).getByRole("link", { name: "Blocked links" }));

    expect(await screen.findByRole("heading", { name: "Blocked links" })).toBeInTheDocument();
    expect(window.location.pathname).toBe("/blocked-links");
    expect(screen.getByRole("link", { name: "Blocked links" })).toHaveAttribute(
      "aria-current",
      "page",
    );

    await userEvent.click(screen.getByRole("link", { name: "knowseek" }));

    expect(await screen.findByLabelText("Search query")).toBeInTheDocument();
    expect(window.location.pathname).toBe("/");
    expect(screen.queryByRole("heading", { name: "Blocked links" })).not.toBeInTheDocument();
  });

  it("shows the links at the bottom of the results page too", async () => {
    mockApi({
      "POST /search": () => ({ query: "x", coverage: "none", hits: [], discovery: null }),
    });
    window.history.replaceState(null, "", "/?q=octopus");
    render(<App />);

    expect(screen.getByRole("navigation", { name: "More pages" })).toBeInTheDocument();
  });
});
