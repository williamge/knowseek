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

    expect(screen.getByText("124.0 MB of 5.0 GB (2%)")).toBeInTheDocument();
    expect(screen.getByText("812.3 KB of 200.0 MB today (0%)")).toBeInTheDocument();
    expect(screen.getByRole("meter", { name: "Disk budget" })).toBeInTheDocument();
    expect(screen.getByRole("meter", { name: "Network budget today" })).toBeInTheDocument();

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
    expect(await screen.findAllByText("No background pages yet.")).toHaveLength(2);
  });

  it("shows the gain of the background pages, and the bytes stored per useful page", async () => {
    mockApi({
      "GET /stats": () =>
        stats({
          pages: { search: 110, background: 20, manual: 10 },
          hit_share: { background_pages: 20, hit_pages: 3 },
          gain: { pages: 4, searches: 9, window_searches: 240 },
          crawl: {
            mode: "on",
            pages_per_day: 100,
            fetched_today: 3,
            fetched: 20,
            links_read: 1234,
            candidates: 87,
            stored_bytes: 2_400_000,
          },
        }),
    });
    render(<App watch={FAST} />);

    expect(await screen.findByRole("heading", { name: "Gain" })).toBeInTheDocument();
    expect(
      screen.getByText(
        "4 of 20 background pages showed up where your other pages were not enough (20%).",
      ),
    ).toBeInTheDocument();
    expect(
      screen.getByText(
        "9 of your 240 searches in the last 30 days were covered only thanks to background pages.",
      ),
    ).toBeInTheDocument();
    expect(
      screen.getByText("Stored per useful page: 600.0 KB (2.4 MB for 20 background pages)."),
    ).toBeInTheDocument();
  });

  it("says so when background pages exist but none was useful yet", async () => {
    mockApi({
      "GET /stats": () =>
        stats({
          pages: { search: 110, background: 20, manual: 10 },
          hit_share: { background_pages: 20, hit_pages: 0 },
          gain: { pages: 0, searches: 0, window_searches: 240 },
          crawl: {
            mode: "on",
            pages_per_day: 100,
            fetched_today: 3,
            fetched: 20,
            links_read: 1234,
            candidates: 87,
            stored_bytes: 2_400_000,
          },
        }),
    });
    render(<App watch={FAST} />);

    expect(
      await screen.findByText("No useful page yet (2.4 MB for 20 background pages)."),
    ).toBeInTheDocument();
    expect(
      screen.getByText(
        "0 of your 240 searches in the last 30 days were covered only thanks to background pages.",
      ),
    ).toBeInTheDocument();
  });

  it("has no gain to show without background pages", async () => {
    mockApi({ "GET /stats": () => stats() });
    render(<App watch={FAST} />);

    expect(await screen.findByRole("heading", { name: "Gain" })).toBeInTheDocument();
    expect(screen.getAllByText("No background pages yet.")).toHaveLength(2);
  });

  it("shows the crawl mode and its counts", async () => {
    mockApi({ "GET /stats": () => stats() });
    render(<App watch={FAST} />);

    expect(await screen.findByRole("heading", { name: "Crawl" })).toBeInTheDocument();
    expect(screen.getByText("Mode: preview. 0 of 100 pages fetched today.")).toBeInTheDocument();
    expect(screen.getByText("1,234 links read, 87 kept as candidates.")).toBeInTheDocument();
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

describe("the index section of the stats page", () => {
  beforeEach(openStats);
  afterEach(() => {
    window.history.pushState(null, "", "/");
    vi.restoreAllMocks();
  });

  const model = {
    name: "ollama/bge-m3:latest",
    digest: "7907646426070047a77226ac3e684fbbe8410524f7b4a74d02837e43f2146bab",
    dimensions: 1024,
    quantization: "float32",
  };

  it("shows the model with a digest cut to 7 characters, and no re-embedding line when current", async () => {
    mockApi({ "GET /stats": () => stats() });
    render(<App watch={FAST} />);

    expect(
      await screen.findByText(
        "Embedding model: ollama/bge-m3:latest (7907646), 1024 dimensions, float32.",
      ),
    ).toBeInTheDocument();
    expect(screen.queryByText(/Re-embedding:/)).not.toBeInTheDocument();
  });

  it("leaves out the brackets when the model has no digest", async () => {
    mockApi({
      "GET /stats": () =>
        stats({
          index: {
            model: { ...model, name: "hashing/1", digest: "" },
            passages: 3,
            current_passages: 3,
            eta_seconds: null,
          },
        }),
    });
    render(<App watch={FAST} />);

    expect(
      await screen.findByText("Embedding model: hashing/1, 1024 dimensions, float32."),
    ).toBeInTheDocument();
  });

  it("says when the provider has not answered", async () => {
    mockApi({
      "GET /stats": () =>
        stats({ index: { model: null, passages: 3, current_passages: 0, eta_seconds: null } }),
    });
    render(<App watch={FAST} />);

    expect(
      await screen.findByText("Embedding model: not known yet (the provider has not answered)."),
    ).toHaveClass("muted");
  });

  it("shows the progress and the time left while passages are left", async () => {
    mockApi({
      "GET /stats": () =>
        stats({ index: { model, passages: 18_300, current_passages: 1240, eta_seconds: 1280 } }),
    });
    render(<App watch={FAST} />);

    expect(
      await screen.findByText(
        "Re-embedding: 1,240 of 18,300 passages, about 22 min left. Until it finishes, older pages are found by keyword only.",
      ),
    ).toBeInTheDocument();
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

  describe("budgets", () => {
    beforeEach(openStats);
    afterEach(() => {
      window.history.pushState(null, "", "/");
      vi.restoreAllMocks();
    });

    const budget = (over: object = {}) => ({ ...stats().budget, ...over });
    const line = (used: number, limit: number, state: "ok" | "near" | "full") => ({
      used,
      limit,
      state,
    });

    it("shows no notice while the budgets are ok", async () => {
      mockApi({ "GET /stats": () => stats() });
      render(<App watch={FAST} />);
      expect(await screen.findByText("Free on this disk: 11.6 GB.")).toBeInTheDocument();
      expect(screen.queryByText(/budget is/)).not.toBeInTheDocument();
      expect(screen.queryByText(/is free on this disk/)).not.toBeInTheDocument();
      expect(screen.queryByText(/cannot be read/)).not.toBeInTheDocument();
    });

    it.each([
      ["near", /^The disk budget is nearly used up: the background crawl/],
      ["full", /^The disk budget is used up: searches no longer fetch/],
    ] as const)("warns when the disk budget is %s", async (state, text) => {
      mockApi({
        "GET /stats": () =>
          stats({ budget: budget({ disk: line(4_600_000_000, 5_000_000_000, state) }) }),
      });
      render(<App watch={FAST} />);
      expect(await screen.findByText(text)).toBeInTheDocument();
      expect(screen.getByText("4.6 GB of 5.0 GB (92%)")).toBeInTheDocument();
    });

    it.each([
      ["near", /^Today's network budget is nearly used up: .* until 00:00 UTC\.$/],
      ["full", /^Today's network budget is used up: searches no longer fetch .* 00:00 UTC\.$/],
    ] as const)("warns when the network budget is %s", async (state, text) => {
      mockApi({
        "GET /stats": () =>
          stats({ budget: budget({ network: line(190_000_000, 200_000_000, state) }) }),
      });
      render(<App watch={FAST} />);
      expect(await screen.findByText(text)).toBeInTheDocument();
    });

    it("says when free disk space is low", async () => {
      mockApi({
        "GET /stats": () =>
          stats({
            budget: budget({ free_disk: { bytes: 500_000_000, floor: 1_000_000_000, low: true } }),
          }),
      });
      render(<App watch={FAST} />);
      expect(await screen.findByText("Free on this disk: 500.0 MB.")).toBeInTheDocument();
      expect(
        screen.getByText(
          "Less than 1.0 GB is free on this disk: the background crawl and the link backfill are paused.",
        ),
      ).toBeInTheDocument();
    });

    it("says when free disk space is unknown, with no notice unless it is low", async () => {
      mockApi({
        "GET /stats": () =>
          stats({
            budget: budget({ free_disk: { bytes: null, floor: 0, low: false } }),
          }),
      });
      render(<App watch={FAST} />);
      expect(await screen.findByText("Free on this disk: unknown.")).toBeInTheDocument();
      expect(screen.queryByText(/cannot be read/)).not.toBeInTheDocument();
    });

    it("says that the pause holds when free disk space is unknown and the check is on", async () => {
      mockApi({
        "GET /stats": () =>
          stats({
            budget: budget({ free_disk: { bytes: null, floor: 1_000_000_000, low: true } }),
          }),
      });
      render(<App watch={FAST} />);
      expect(await screen.findByText("Free on this disk: unknown.")).toBeInTheDocument();
      expect(
        screen.getByText(
          "Free disk space cannot be read: the background crawl and the link backfill are paused.",
        ),
      ).toBeInTheDocument();
    });

    it("counts passages, and notes search speed only from 100,000", async () => {
      const note = /gets slower as this number grows/;
      mockApi({ "GET /stats": () => stats({ passages: 99_999 }) });
      const first = render(<App watch={FAST} />);
      expect(await screen.findByText("99,999 passages stored.")).toBeInTheDocument();
      expect(screen.queryByText(note)).not.toBeInTheDocument();
      first.unmount();
      vi.restoreAllMocks();

      mockApi({ "GET /stats": () => stats({ passages: 100_000 }) });
      render(<App watch={FAST} />);
      expect(await screen.findByText("100,000 passages stored.")).toBeInTheDocument();
      expect(screen.getByText(note)).toBeInTheDocument();
    });
  });
});
