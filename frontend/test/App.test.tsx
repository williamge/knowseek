import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it } from "vitest";
import { App } from "../src/App";
import { document as doc, hit, mockApi, result, topic } from "./fixtures";

const FAST = { intervalMs: 10, timeoutMs: 2000, quietChecks: 2 };

describe("App", () => {
  it("shows a centered search box on the home page and runs a search", async () => {
    const { calls } = mockApi({
      "GET /topics": () => [],
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
    const { calls } = mockApi({ "GET /topics": () => [], "GET /documents": () => [] });
    render(<App watch={FAST} />);
    await userEvent.type(screen.getByLabelText("Search query"), "   {Enter}");
    expect(calls.some((c) => c.key === "POST /search")).toBe(false);
  });

  it("searches again when discovery adds documents", async () => {
    window.history.replaceState(null, "", "/?q=octopus");
    let searches = 0;
    let listCalls = 0;
    mockApi({
      "GET /topics": () => [],
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

  it("shows an empty state, not unrelated results, while discovery runs", async () => {
    window.history.replaceState(null, "", "/?q=heavy+metal");
    mockApi({
      "GET /topics": () => [],
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
      "GET /topics": () => [],
      "POST /search": () =>
        new Response(JSON.stringify({ errors: { detail: "boom" } }), { status: 500 }),
    });
    render(<App watch={FAST} />);
    expect(await screen.findByRole("alert")).toHaveTextContent("boom");
  });

  it("follows and unfollows a topic from the results", async () => {
    window.history.replaceState(null, "", "/?q=octopus");
    const { calls } = mockApi({
      "GET /topics": () => [],
      "POST /search": () => result(),
      "POST /topics": () => topic(),
      "DELETE /topics/topic-1": () => new Response(null, { status: 204 }),
    });
    render(<App watch={FAST} />);

    await userEvent.click(await screen.findByRole("button", { name: "+ Follow topic" }));
    const following = await screen.findByRole("button", { name: "✓ Following" });
    expect(calls.find((c) => c.key === "POST /topics")?.body).toEqual({
      topic: { query: "octopus" },
    });

    await userEvent.click(following);
    await waitFor(() =>
      expect(screen.getByRole("button", { name: "+ Follow topic" })).toBeInTheDocument(),
    );
  });

  it("opens a document in the reader and closes it with Escape", async () => {
    window.history.replaceState(null, "", "/?q=octopus");
    mockApi({
      "GET /topics": () => [],
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

  it("lists topics on the topics page", async () => {
    window.history.replaceState(null, "", "/topics");
    mockApi({ "GET /topics": () => [topic({ query: "fusion energy" })] });
    render(<App watch={FAST} />);
    expect(await screen.findByText("fusion energy")).toBeInTheDocument();
    expect(screen.getByText(/Checked every day/)).toBeInTheDocument();
  });
});
