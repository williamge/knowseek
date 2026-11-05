import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { App } from "../src/App";
import { PlannerPlayground } from "../src/components/PlannerPlayground";
import { ADR_QUERIES, resultsToMarkdown, thinkingHint, type ModelRun } from "../src/lib/planner";
import { mockApi, plannerModels, plannerPreview, plannerResult } from "./fixtures";

type PreviewBody = { query: string; models: string[]; source: boolean };

const coder = plannerResult({
  model: "qwen2.5-coder:7b",
  status: "fallback",
  detail: "{:ollama, 404, ...}",
  warm: false,
  plan_ms: 7300,
  queries: ["tide pools"],
  source: {
    literal: { titles: ["Tide pool", "Tide"], error: null },
    searches: [],
    only_planned: [],
    wiki_ms: 0,
  },
});

describe("PlannerPlayground", () => {
  it("lists the installed chat models with their size, and selects only the default", async () => {
    mockApi({ "GET /planner/models": () => plannerModels() });
    render(<PlannerPlayground />);

    const small = await screen.findByRole("checkbox", { name: /qwen2\.5:3b/ });
    const big = screen.getByRole("checkbox", { name: /qwen2\.5-coder:7b/ });

    expect(small).toBeChecked();
    expect(big).not.toBeChecked();
    expect(screen.getByText("1.9 GB, 3.1B")).toBeInTheDocument();
    expect(screen.getByText("4.7 GB, 7.6B")).toBeInTheDocument();
    expect(screen.getByText("default")).toBeInTheDocument();
    expect(screen.queryByText(/16 GB machine/)).not.toBeInTheDocument();
  });

  it("warns when several models are selected, and shows the server's warning", async () => {
    mockApi({
      "GET /planner/models": () => plannerModels({ warning: "2 chat models are loaded now" }),
    });
    render(<PlannerPlayground />);

    await userEvent.click(await screen.findByRole("checkbox", { name: /qwen2\.5-coder:7b/ }));

    expect(screen.getByText(/2 models selected/)).toHaveTextContent(
      "Loading several large models on a 16 GB machine slows search",
    );
    expect(screen.getByText("2 chat models are loaded now")).toBeInTheDocument();
  });

  it("shows an error when the models cannot be listed", async () => {
    mockApi({
      "GET /planner/models": () =>
        new Response(JSON.stringify({ errors: { detail: "Ollama did not answer" } }), {
          status: 503,
        }),
    });
    render(<PlannerPlayground />);

    expect(await screen.findByRole("alert")).toHaveTextContent("Ollama did not answer");
  });

  it("does not run without a query or a model", async () => {
    mockApi({ "GET /planner/models": () => plannerModels() });
    render(<PlannerPlayground />);

    const run = await screen.findByRole("button", { name: "Run" });
    expect(run).toBeDisabled();

    await userEvent.type(screen.getByLabelText("Planner query"), "tide pools");
    expect(run).toBeEnabled();

    await userEvent.click(screen.getByRole("checkbox", { name: /qwen2\.5:3b/ }));
    expect(run).toBeDisabled();
  });

  it("calls the endpoint once per selected model, smallest first, and fills in as each answers", async () => {
    // Hold the first answer, so the page can be looked at in between.
    let release: (response: Response) => void = () => {};
    const calls: PreviewBody[] = [];
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
      if (String(input) === "/api/planner/models") {
        return new Response(JSON.stringify({ data: plannerModels() }));
      }
      const body = JSON.parse(String(init?.body)) as PreviewBody;
      calls.push(body);
      if (calls.length === 1) return new Promise<Response>((resolve) => (release = resolve));
      return new Response(JSON.stringify({ data: plannerPreview(coder) }));
    });

    render(<PlannerPlayground />);
    await userEvent.click(await screen.findByRole("checkbox", { name: /qwen2\.5-coder:7b/ }));
    await userEvent.type(screen.getByLabelText("Planner query"), "tide pools");
    await userEvent.click(screen.getByRole("button", { name: "Run" }));

    const first = await screen.findByRole("article", { name: "Result of qwen2.5:3b" });
    const second = screen.getByRole("article", { name: "Result of qwen2.5-coder:7b" });
    expect(within(first).getByRole("status")).toHaveTextContent("Running");
    expect(within(second).getByText(/Waiting for its turn/)).toBeInTheDocument();
    expect(calls).toEqual([{ query: "tide pools", models: ["qwen2.5:3b"], source: true }]);

    release(new Response(JSON.stringify({ data: plannerPreview(plannerResult()) })));

    await within(second).findByText(/Plan time/);
    expect(within(first).getByText("0.63 s")).toBeInTheDocument();
    expect(calls.map((call) => call.models)).toEqual([["qwen2.5:3b"], ["qwen2.5-coder:7b"]]);
  });

  it("shows the plan, the latency, the status and the two columns, with the extra titles marked", async () => {
    mockApi({
      "GET /planner/models": () => plannerModels(),
      "POST /planner/preview": () => plannerPreview(plannerResult()),
    });
    render(<PlannerPlayground />);

    await userEvent.type(await screen.findByLabelText("Planner query"), "tide pools{Enter}");

    const card = await screen.findByRole("article", { name: "Result of qwen2.5:3b" });
    await within(card).findByText("0.63 s");
    expect(within(card).getByText("ok")).toBeInTheDocument();
    expect(within(card).getByText(/model was loaded/)).toBeInTheDocument();
    expect(within(card).getByText("420 ms")).toBeInTheDocument();

    // The query as typed is the first chip, then the planned queries.
    const chips = card.querySelectorAll(".planner__plan .chip");
    expect([...chips].map((chip) => chip.textContent)).toEqual([
      "tide pools",
      "rock pool",
      "intertidal zone",
    ]);

    const literal = within(card).getByRole("region", { name: "Literal search found" });
    expect(
      within(literal)
        .getAllByRole("listitem")
        .map((li) => li.textContent),
    ).toEqual(["Tide pool", "Tide"]);

    const planned = within(card).getByRole("region", { name: "Planned searches also found" });
    expect(
      within(planned)
        .getAllByRole("listitem")
        .map((li) => li.textContent),
    ).toEqual(["Tide pool", "Rock pool", "Intertidal zone"]);
    expect([...planned.querySelectorAll("mark")].map((mark) => mark.textContent)).toEqual([
      "Rock pool",
      "Intertidal zone",
    ]);
  });

  it("shows what a model that fell back said, and that it includes loading", async () => {
    mockApi({
      "GET /planner/models": () => plannerModels(),
      "POST /planner/preview": () => plannerPreview(coder),
    });
    render(<PlannerPlayground />);

    await userEvent.type(await screen.findByLabelText("Planner query"), "tide pools{Enter}");

    const card = await screen.findByRole("article", { name: /qwen2\.5:3b/ });
    expect(await within(card).findByText("fallback")).toBeInTheDocument();
    expect(within(card).getByText(/Planner said: \{:ollama, 404/)).toBeInTheDocument();
    expect(within(card).getByText(/includes loading the model/)).toBeInTheDocument();
    expect(within(card).getByText("no planned queries")).toBeInTheDocument();
  });

  it("shows the error of a model that failed and still renders the others", async () => {
    mockApi({
      "GET /planner/models": () => plannerModels(),
      "POST /planner/preview": (body) =>
        (body as PreviewBody).models[0] === "qwen2.5:3b"
          ? new Response(JSON.stringify({ errors: { detail: "Ollama did not answer" } }), {
              status: 503,
            })
          : plannerPreview(coder),
    });
    render(<PlannerPlayground />);

    await userEvent.click(await screen.findByRole("checkbox", { name: /qwen2\.5-coder:7b/ }));
    await userEvent.type(screen.getByLabelText("Planner query"), "tide pools");
    await userEvent.click(screen.getByRole("button", { name: "Run" }));

    const failed = await screen.findByRole("article", { name: "Result of qwen2.5:3b" });
    expect(await within(failed).findByRole("alert")).toHaveTextContent(
      "Failed: Ollama did not answer",
    );

    const other = screen.getByRole("article", { name: "Result of qwen2.5-coder:7b" });
    expect(await within(other).findByText("7.30 s")).toBeInTheDocument();
  });

  it("runs an example query of ADR 0025 with one click", async () => {
    const { calls } = mockApi({
      "GET /planner/models": () => plannerModels(),
      "POST /planner/preview": () => plannerPreview(plannerResult()),
    });
    render(<PlannerPlayground />);
    await screen.findByRole("checkbox", { name: /qwen2\.5:3b/ });

    expect(ADR_QUERIES).toHaveLength(12);
    await userEvent.click(screen.getByText(/Try the 12 queries/));
    await userEvent.click(screen.getByRole("button", { name: "knicks" }));

    await screen.findByRole("article", { name: "Result of qwen2.5:3b" });
    expect(screen.getByLabelText("Planner query")).toHaveValue("knicks");
    expect(calls.find((call) => call.key === "POST /planner/preview")?.body).toMatchObject({
      query: "knicks",
      models: ["qwen2.5:3b"],
    });
  });

  it("copies the results as markdown", async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, "clipboard", { value: { writeText }, configurable: true });
    mockApi({
      "GET /planner/models": () => plannerModels(),
      "POST /planner/preview": () => plannerPreview(plannerResult()),
    });
    render(<PlannerPlayground />);

    await userEvent.type(await screen.findByLabelText("Planner query"), "tide pools{Enter}");
    await userEvent.click(await screen.findByRole("button", { name: "Copy results as markdown" }));

    expect(await screen.findByText("Copied.")).toBeInTheDocument();
    expect(writeText).toHaveBeenCalledWith(
      [
        '## Planner playground: "tide pools"',
        "",
        "Literal search found: Tide pool; Tide",
        "",
        "### qwen2.5:3b (1.9 GB)",
        "- Status: ok",
        "- Plan time: 0.63 s, model was loaded",
        "- Queries: `tide pools` (as typed), `rock pool`, `intertidal zone`",
        "- Planned searches also found: Tide pool; Rock pool; Intertidal zone",
        "- Only planning found: Rock pool; Intertidal zone",
        "- Wikipedia time for the planned searches: 420 ms",
        "",
      ].join("\n"),
    );
  });

  it("shows the markdown to copy by hand when the clipboard is not available", async () => {
    Object.defineProperty(navigator, "clipboard", {
      value: { writeText: vi.fn().mockRejectedValue(new Error("denied")) },
      configurable: true,
    });
    mockApi({
      "GET /planner/models": () => plannerModels(),
      "POST /planner/preview": () => plannerPreview(plannerResult()),
    });
    render(<PlannerPlayground />);

    await userEvent.type(await screen.findByLabelText("Planner query"), "tide pools{Enter}");
    await userEvent.click(await screen.findByRole("button", { name: "Copy results as markdown" }));

    const manual = await screen.findByLabelText("Markdown results");
    expect((manual as HTMLTextAreaElement).value).toContain("### qwen2.5:3b (1.9 GB)");
  });
});

describe("thinkingHint", () => {
  it("flags thinking models and no others", () => {
    for (const name of [
      "qwen3:4b",
      "qwen3:4b-thinking",
      "deepseek-r1:1.5b",
      "lfm2.5-thinking:1.2b",
    ]) {
      expect(thinkingHint(name)).toBe("thinking model: not suited");
    }
    for (const name of [
      "qwen3:4b-instruct",
      "qwen3:1.7b",
      "qwen3:4b-q4_K_M",
      "granite4:1b-h",
      "phi4-mini",
    ]) {
      expect(thinkingHint(name)).toBeNull();
    }
  });

  it("is shown next to the model in the list, with the memory note", async () => {
    const models = plannerModels();
    models.models.push({
      name: "qwen3:4b",
      size_bytes: 2_500_000_000,
      parameter_size: "4.0B",
      default: false,
      loaded: false,
    });
    mockApi({ "GET /planner/models": () => models });
    render(<PlannerPlayground />);

    const row = (await screen.findByRole("checkbox", { name: /qwen3:4b/ })).closest("label")!;
    expect(within(row).getByText("thinking model: not suited")).toBeInTheDocument();
    expect(screen.getByText(/never bge-m3/)).toBeInTheDocument();
    expect(
      within(screen.getByRole("checkbox", { name: /qwen2\.5:3b/ }).closest("label")!).queryByText(
        /thinking model/,
      ),
    ).toBeNull();
  });
});

describe("resultsToMarkdown", () => {
  it("writes failures and models that did not run, and a failed literal search", () => {
    const runs: ModelRun[] = [
      { model: "qwen2.5:3b", state: "failed", error: "Ollama did not answer" },
      { model: "qwen2.5-coder:7b", state: "waiting" },
      {
        model: "other:1b",
        state: "done",
        result: plannerResult({
          model: "other:1b",
          warm: false,
          source: {
            literal: { titles: [], error: "http_status" },
            searches: [{ query: "rock pool", titles: [], error: "boom" }],
            only_planned: [],
            wiki_ms: 5,
          },
        }),
      },
    ];

    const text = resultsToMarkdown("q", runs, { titles: [], error: "http_status", ms: 1 }, []);

    expect(text).toContain("Literal search found: error (http_status)");
    expect(text).toContain("### qwen2.5:3b\n- Failed: Ollama did not answer");
    expect(text).toContain("### qwen2.5-coder:7b\n- Not run");
    expect(text).toContain("- Plan time: 0.63 s, includes model load");
    expect(text).toContain("- Planned searches also found: (nothing)");
    expect(text).toContain("- Search `rock pool` failed: boom");
  });
});

describe("the planner page in the app", () => {
  it("is at /planner, with a link from the home page", async () => {
    mockApi({ "GET /documents": () => [] });
    const { unmount } = render(<App />);
    expect(await screen.findByRole("link", { name: "planner" })).toHaveAttribute(
      "href",
      "/planner",
    );
    unmount();

    window.history.replaceState(null, "", "/planner");
    mockApi({ "GET /planner/models": () => plannerModels() });
    render(<App />);

    expect(await screen.findByText("planner playground")).toBeInTheDocument();
    await waitFor(() =>
      expect(screen.getByRole("checkbox", { name: /qwen2\.5:3b/ })).toBeChecked(),
    );
  });
});
