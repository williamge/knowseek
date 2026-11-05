import type { PlannerModel, PlannerModelResult, PlannerPreview } from "../types";

/** The 12 queries of the real-Wikipedia table in ADR 0025, to try a model on. */
export const ADR_QUERIES: readonly string[] = [
  "what's new in battery chemistry for evs",
  "how do vector databases index embeddings",
  "knicks",
  "nvidia",
  "mercury",
  "java",
  "why is the sky blue",
  "i keep hearing about this thing where companies train smaller models from bigger ones to make them cheaper to run but i do not really get how that works or why it would not just lose all the quality, can someone explain it to me",
  "histoire de la tour Eiffel",
  "pythn asyncronous programing explaned",
  "latest developments in nuclear fusion energy",
  "Wie funktioniert ein Kernreaktor",
];

/** One model of a run: waiting its turn, running, or finished. */
export type ModelRun =
  | { model: string; state: "waiting" | "running" }
  | { model: string; state: "done"; result: PlannerModelResult }
  | { model: string; state: "failed"; error: string };

/**
 * A hint for models that think before they answer, which a query planner does
 * not need: they spend the token budget on reasoning, and thinking-only ones
 * (`qwen3:4b` is the 2507 thinking build, `qwen3:4b-instruct` is the
 * non-thinking one) cannot be switched off. `null` when the name is fine.
 */
export function thinkingHint(name: string): string | null {
  const thinking =
    name === "qwen3:4b" || /thinking/i.test(name) || /(^|[-_/:])r1([-_.:]|$)/i.test(name);
  return thinking ? "thinking model: not suited" : null;
}

export function formatGb(bytes: number): string {
  return `${(bytes / 1e9).toFixed(1)} GB`;
}

export function formatSeconds(ms: number): string {
  return `${(ms / 1000).toFixed(2)} s`;
}

/** "qwen2.5:3b (1.9 GB)" when the size is known. */
export function modelLabel(name: string, models: PlannerModel[]): string {
  const model = models.find((m) => m.name === name);
  return model ? `${name} (${formatGb(model.size_bytes)})` : name;
}

/** Titles that the planned searches found, each once, in order. */
export function plannedTitles(result: PlannerModelResult): string[] {
  const titles = result.source?.searches.flatMap((search) => search.titles) ?? [];
  return [...new Set(titles)];
}

/**
 * The run as markdown, to paste into a chat: the query, then for each model
 * its plan, its time, and what the literal and the planned searches found.
 */
export function resultsToMarkdown(
  query: string,
  runs: ModelRun[],
  literal: PlannerPreview["literal"],
  models: PlannerModel[],
): string {
  const lines = [`## Planner playground: ${JSON.stringify(query)}`, ""];
  if (literal) {
    lines.push(
      `Literal search found: ${literal.error ? `error (${literal.error})` : list(literal.titles)}`,
      "",
    );
  }

  for (const run of runs) {
    lines.push(`### ${modelLabel(run.model, models)}`);
    if (run.state === "failed") lines.push(`- Failed: ${run.error}`);
    else if (run.state !== "done") lines.push("- Not run");
    else lines.push(...resultLines(run.result));
    lines.push("");
  }
  return lines.join("\n").trimEnd() + "\n";
}

function resultLines(result: PlannerModelResult): string[] {
  const warm =
    result.warm === null ? "" : result.warm ? ", model was loaded" : ", includes model load";
  const status = result.detail ? `${result.status} (${result.detail})` : result.status;
  const [original = "", ...planned] = result.queries;
  const lines = [
    `- Status: ${status}`,
    `- Plan time: ${formatSeconds(result.plan_ms)}${warm}`,
    `- Queries: ${[`\`${original}\` (as typed)`, ...planned.map((q) => `\`${q}\``)].join(", ")}`,
  ];

  const source = result.source;
  if (source) {
    lines.push(
      `- Planned searches also found: ${list(plannedTitles(result))}`,
      `- Only planning found: ${list(source.only_planned)}`,
      `- Wikipedia time for the planned searches: ${source.wiki_ms} ms`,
    );
    for (const search of source.searches.filter((s) => s.error)) {
      lines.push(`- Search \`${search.query}\` failed: ${search.error}`);
    }
  }
  return lines;
}

function list(titles: string[]): string {
  return titles.length > 0 ? titles.join("; ") : "(nothing)";
}
