import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { App } from "../src/App";
import { document as doc, mockApi, stats } from "./fixtures";

const FAST = { intervalMs: 10, timeoutMs: 2000, quietChecks: 2 };

function openStats() {
  window.history.pushState(null, "", "/stats");
}

describe("the stats page", () => {
  beforeEach(openStats);
  afterEach(() => {
    window.history.pushState(null, "", "/");
    vi.restoreAllMocks();
  });

  it("shows the numbers", async () => {
    mockApi({ "GET /stats": () => stats() });
    render(<App watch={FAST} />);

    expect(await screen.findByText("42 searches recorded.")).toBeInTheDocument();

    const searches = screen.getAllByRole("table")[0];
    const rows = within(searches).getAllByRole("row");
    // Header, then one row per day with its sum and the coverage mix.
    expect(
      within(rows[0])
        .getAllByRole("columnheader")
        .map((c) => c.textContent),
    ).toEqual(["Day", "Searches", "Well covered", "Partly covered", "Not covered"]);
    expect(
      within(rows[1])
        .getAllByRole("cell")
        .map((c) => c.textContent),
    ).toEqual(["6", "3", "1", "2"]);
    expect(within(rows[1]).getByRole("rowheader")).toHaveTextContent("Nov 10");
    expect(
      within(rows[2])
        .getAllByRole("cell")
        .map((c) => c.textContent),
    ).toEqual(["4", "0", "0", "4"]);

    const pages = screen.getAllByRole("table")[1];
    expect(within(pages).getByRole("row", { name: "From a search 110" })).toBeInTheDocument();
    expect(within(pages).getByRole("row", { name: "Background 0" })).toBeInTheDocument();
    expect(within(pages).getByRole("row", { name: "Added manually 10" })).toBeInTheDocument();

    expect(screen.getByText("73.4 MB (the database file).")).toBeInTheDocument();

    const network = screen.getAllByRole("table")[2];
    expect(
      within(network).getByRole("row", { name: "Nov 10 wikipedia 512.0 KB" }),
    ).toBeInTheDocument();
    expect(
      within(network).getByRole("row", { name: "Nov 10 wikibooks 900 B" }),
    ).toBeInTheDocument();
  });

  it("shows the hit share of the background pages, or says there are none", async () => {
    mockApi({
      "GET /stats": () => stats({ hit_share: { background_pages: 20, hit_pages: 3 } }),
    });
    const { unmount } = render(<App watch={FAST} />);
    expect(
      await screen.findByText("3 of 20 background pages showed up in your top results (15%)."),
    ).toBeInTheDocument();
    unmount();
    vi.restoreAllMocks();

    mockApi({ "GET /stats": () => stats() });
    render(<App watch={FAST} />);
    expect(await screen.findByText("No background pages yet.")).toBeInTheDocument();
  });

  it("says so when nothing was downloaded", async () => {
    mockApi({ "GET /stats": () => stats({ network: [] }) });
    render(<App watch={FAST} />);

    expect(await screen.findByText("Nothing downloaded in the last 30 days.")).toBeInTheDocument();
  });

  it("clears the search history after a confirmation, then loads again", async () => {
    let cleared = false;
    const { calls } = mockApi({
      "GET /stats": () => (cleared ? stats({ searches: { total: 0, days: [] } }) : stats()),
      "DELETE /searches": () => {
        cleared = true;
        return { deleted: 42 };
      },
    });
    const confirm = vi.spyOn(window, "confirm").mockReturnValue(true);
    render(<App watch={FAST} />);

    await userEvent.click(await screen.findByRole("button", { name: "Clear search history" }));

    expect(confirm).toHaveBeenCalledWith("Delete every recorded search?");
    expect(await screen.findByText("0 searches recorded.")).toBeInTheDocument();
    expect(calls.map((c) => c.key)).toEqual(["GET /stats", "DELETE /searches", "GET /stats"]);
    // Only the pages and network tables are left.
    expect(screen.getAllByRole("table")).toHaveLength(2);
  });

  it("does nothing when the confirmation is declined", async () => {
    const { calls } = mockApi({ "GET /stats": () => stats() });
    vi.spyOn(window, "confirm").mockReturnValue(false);
    render(<App watch={FAST} />);

    await userEvent.click(await screen.findByRole("button", { name: "Clear search history" }));

    expect(calls.map((c) => c.key)).toEqual(["GET /stats"]);
  });

  it("shows an alert when the stats cannot be loaded", async () => {
    mockApi({
      "GET /stats": () =>
        new Response(JSON.stringify({ errors: { detail: "The database is busy." } }), {
          status: 500,
        }),
    });
    render(<App watch={FAST} />);

    expect(await screen.findByRole("alert")).toHaveTextContent("The database is busy.");
  });
});

describe("the nav", () => {
  afterEach(() => {
    window.history.pushState(null, "", "/");
    vi.restoreAllMocks();
  });

  it("opens the stats page from the home page, and the wordmark returns home", async () => {
    mockApi({ "GET /documents": () => [doc()], "GET /stats": () => stats() });
    render(<App watch={FAST} />);

    await userEvent.click(screen.getByRole("link", { name: "Stats" }));

    expect(await screen.findByRole("heading", { name: "Stats" })).toBeInTheDocument();
    expect(window.location.pathname).toBe("/stats");
    expect(screen.getByRole("link", { name: "Stats" })).toHaveAttribute("aria-current", "page");

    await userEvent.click(screen.getByRole("link", { name: "knowseek" }));

    expect(await screen.findByLabelText("Search query")).toBeInTheDocument();
    expect(window.location.pathname).toBe("/");
  });
});
