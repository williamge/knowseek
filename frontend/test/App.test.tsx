import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it } from "vitest";
import { App } from "../src/App";
import { document as doc, hit, mockApi, result } from "./fixtures";

const FAST = { intervalMs: 10, timeoutMs: 2000, quietChecks: 2 };

describe("App", () => {
  it("shows a centered search box on the home page and runs a search", async () => {
    const { calls } = mockApi({
      "GET /documents": () => [],
      "POST /search": () => result({ hits: [hit({ title: "Octopus", content: "Nine brains." })] }),
    });
    render(<App watch={FAST} />);

    await userEvent.type(screen.getByLabelText("Search query"), "octopus{Enter}");

    expect(await screen.findByRole("button", { name: "Octopus" })).toBeInTheDocument();
    expect(window.location.search).toBe("?q=octopus");
    expect(calls.find((c) => c.key === "POST /search")?.body).toMatchObject({ query: "octopus" });
    expect(screen.getByText("Well covered")).toBeInTheDocument();
  });

  it("does not search for an empty query", async () => {
    const { calls } = mockApi({ "GET /documents": () => [] });
    render(<App watch={FAST} />);
    await userEvent.type(screen.getByLabelText("Search query"), "   {Enter}");
    expect(calls.some((c) => c.key === "POST /search")).toBe(false);
  });

  it("searches again when discovery adds documents", async () => {
    window.history.replaceState(null, "", "/?q=octopus");
    let searches = 0;
    let listCalls = 0;
    mockApi({
      // The first call is the baseline. Later calls include a new document.
      "GET /documents": () => {
        listCalls += 1;
        return listCalls === 1 ? [doc({ id: "old" })] : [doc({ id: "new" }), doc({ id: "old" })];
      },
      "POST /search": () => {
        searches += 1;
        if (searches === 1) {
          return result({
            coverage: "none",
            discovery: { status: "enqueued", job_id: 1 },
            hits: [],
          });
        }
        return result({ hits: [hit({ chunk_id: "c-new", document_id: "new", title: "Fresh" })] });
      },
    });
    render(<App watch={FAST} />);

    expect(await screen.findByRole("button", { name: "Fresh" })).toBeInTheDocument();
    expect(screen.getByText("new")).toBeInTheDocument();
    expect(searches).toBe(2);
  });

  it("finds a document again after a failed search, so its results still appear", async () => {
    window.history.replaceState(null, "", "/?q=octopus");
    let searches = 0;
    let listCalls = 0;
    mockApi({
      "GET /documents": () => {
        listCalls += 1;
        return listCalls === 1 ? [doc({ id: "old" })] : [doc({ id: "new" }), doc({ id: "old" })];
      },
      "POST /search": () => {
        searches += 1;
        if (searches === 1) {
          return result({
            coverage: "none",
            discovery: { status: "enqueued", job_id: 1 },
            hits: [],
          });
        }
        // The first re-search fails. The next check must try it again.
        if (searches === 2) return new Response("{}", { status: 500 });
        return result({ hits: [hit({ chunk_id: "c-new", document_id: "new", title: "Fresh" })] });
      },
    });
    render(<App watch={FAST} />);

    expect(await screen.findByRole("button", { name: "Fresh" })).toBeInTheDocument();
    expect(searches).toBe(3);
  });

  it("counts a document that arrives while the first search runs", async () => {
    window.history.replaceState(null, "", "/?q=octopus");
    let searches = 0;
    let arrived = false;
    mockApi({
      // The baseline list is read before the search, so it does not have "new".
      "GET /documents": () => (arrived ? [doc({ id: "new" })] : []),
      "POST /search": () => {
        searches += 1;
        if (searches === 1) {
          arrived = true;
          return result({
            coverage: "none",
            discovery: { status: "enqueued", job_id: 1 },
            hits: [],
          });
        }
        return result({ hits: [hit({ chunk_id: "c-new", document_id: "new", title: "Fresh" })] });
      },
    });
    render(<App watch={FAST} />);

    expect(await screen.findByRole("button", { name: "Fresh" })).toBeInTheDocument();
  });

  it("runs the search again when the user submits the same query", async () => {
    window.history.replaceState(null, "", "/?q=octopus");
    const { calls } = mockApi({
      "POST /search": () => result(),
    });
    render(<App watch={FAST} />);
    await screen.findByText("Well covered");

    await userEvent.click(screen.getByLabelText("Search query"));
    await userEvent.keyboard("{Enter}");

    await waitFor(() =>
      expect(calls.filter((call) => call.key === "POST /search")).toHaveLength(2),
    );
  });

  it("shows an empty state, not unrelated results, while discovery runs", async () => {
    window.history.replaceState(null, "", "/?q=heavy+metal");
    mockApi({
      "GET /documents": () => [doc({ id: "old" })],
      "POST /search": () =>
        result({ coverage: "none", discovery: { status: "enqueued", job_id: 1 }, hits: [] }),
    });
    render(<App watch={{ intervalMs: 60_000, timeoutMs: 120_000, quietChecks: 2 }} />);

    expect(await screen.findByText("Nothing in the index matches this yet.")).toBeInTheDocument();
    expect(screen.getByText("Not covered yet")).toBeInTheDocument();
    expect(screen.getByText(/Looking for new sources/)).toBeInTheDocument();
    expect(screen.queryByRole("article")).not.toBeInTheDocument();
  });

  it("shows an error when the search fails", async () => {
    window.history.replaceState(null, "", "/?q=octopus");
    mockApi({
      "POST /search": () =>
        new Response(JSON.stringify({ errors: { detail: "boom" } }), { status: 500 }),
    });
    render(<App watch={FAST} />);
    expect(await screen.findByRole("alert")).toHaveTextContent("boom");
  });

  it("opens a document in the reader and closes it with Escape", async () => {
    window.history.replaceState(null, "", "/?q=octopus");
    mockApi({
      "POST /search": () => result({ hits: [hit({ document_id: "doc-1", title: "Doc one" })] }),
      "GET /documents/doc-1": () => doc(),
    });
    render(<App watch={FAST} />);

    await userEvent.click(await screen.findByRole("button", { name: "Doc one" }));
    expect(await screen.findByRole("dialog")).toHaveTextContent("Second paragraph");
    expect(window.location.search).toContain("doc=doc-1");

    await userEvent.keyboard("{Escape}");
    await waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument());
  });
});
