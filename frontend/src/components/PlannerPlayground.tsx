import { useEffect, useRef, useState, type FormEvent } from "react";
import { api } from "../api";
import {
  ADR_QUERIES,
  formatGb,
  formatSeconds,
  modelLabel,
  plannedTitles,
  resultsToMarkdown,
  thinkingHint,
  type ModelRun,
} from "../lib/planner";
import type { PlannerModelResult, PlannerModels, PlannerPreview } from "../types";

type Catalog =
  | { state: "loading" }
  | { state: "error"; message: string }
  | { state: "ready"; data: PlannerModels };

type Copy = "idle" | "copied" | "manual";

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/**
 * Dev-only page (`/planner`, ADR 0025): run a query through one or more local
 * chat models used as query planners and compare what Wikipedia's search finds
 * for the query as typed and for the planned queries. Nothing is indexed.
 *
 * The models run one after another on the server (RAM), so the page asks for
 * one model at a time and fills in as each answer arrives.
 */
export function PlannerPlayground() {
  const [catalog, setCatalog] = useState<Catalog>({ state: "loading" });
  const [selected, setSelected] = useState<string[]>([]);
  const [query, setQuery] = useState("");
  const [asked, setAsked] = useState("");
  const [runs, setRuns] = useState<ModelRun[]>([]);
  const [literal, setLiteral] = useState<PlannerPreview["literal"]>(null);
  const [running, setRunning] = useState(false);
  const [copy, setCopy] = useState<Copy>("idle");
  // A newer run, or leaving the page, stops the older run from writing state.
  const currentRun = useRef(0);

  useEffect(() => {
    const controller = new AbortController();
    api
      .plannerModels(controller.signal)
      .then((data) => {
        setCatalog({ state: "ready", data });
        // Only the configured model is selected: one model in memory.
        if (data.models.some((model) => model.name === data.default)) setSelected([data.default]);
      })
      .catch((error: unknown) => {
        if (!controller.signal.aborted) setCatalog({ state: "error", message: messageOf(error) });
      });
    return () => {
      controller.abort();
      currentRun.current += 1;
    };
  }, []);

  const models = catalog.state === "ready" ? catalog.data.models : [];

  const run = async (text: string) => {
    const trimmed = text.trim();
    // Smallest model first, as listed: the cheap answers arrive first.
    const order = models.map((model) => model.name).filter((name) => selected.includes(name));
    if (!trimmed || order.length === 0) return;

    const id = ++currentRun.current;
    const update = (model: string, next: ModelRun) =>
      setRuns((all) => all.map((entry) => (entry.model === model ? next : entry)));

    setAsked(trimmed);
    setLiteral(null);
    setCopy("idle");
    setRunning(true);
    setRuns(order.map((model) => ({ model, state: "waiting" })));

    for (const model of order) {
      update(model, { model, state: "running" });
      try {
        const preview = await api.plannerPreview(trimmed, [model]);
        if (currentRun.current !== id) return;
        const result = preview.results[0];
        if (!result) throw new Error("The server returned no result for this model.");
        setLiteral((first) => first ?? preview.literal);
        update(model, { model, state: "done", result });
      } catch (error) {
        if (currentRun.current !== id) return;
        update(model, { model, state: "failed", error: messageOf(error) });
      }
    }
    if (currentRun.current === id) setRunning(false);
  };

  const submit = (event: FormEvent) => {
    event.preventDefault();
    void run(query);
  };

  const toggle = (name: string) =>
    setSelected((all) => (all.includes(name) ? all.filter((n) => n !== name) : [...all, name]));

  const markdown = resultsToMarkdown(asked, runs, literal, models);
  const copyResults = async () => {
    try {
      await navigator.clipboard.writeText(markdown);
      setCopy("copied");
    } catch {
      setCopy("manual");
    }
  };

  const canRun = query.trim() !== "" && selected.length > 0 && !running;
  const finished = runs.some((entry) => entry.state === "done" || entry.state === "failed");

  return (
    <div className="app">
      <header className="topbar">
        <a className="wordmark wordmark--small" href="/">
          knowseek
        </a>
        <span className="planner__title">
          planner playground <span className="badge badge--partial">dev only</span>
        </span>
      </header>

      <main className="page planner">
        <p className="planner__intro">
          Try local chat models as query planners (task 007, ADR 0025). Each model turns your query
          into a few search queries; Wikipedia&apos;s search then shows what they find that the
          query as typed does not. Nothing is indexed.
        </p>
        <p className="planner__muted">
          Memory: the models run strictly one at a time, and after each one Ollama is told to unload
          that model (never bge-m3, which search needs), so memory goes back to where it was. Every
          run therefore includes the time to load its model.
        </p>

        <form className="planner__form" onSubmit={submit}>
          <label className="planner__field">
            <span>Query</span>
            <textarea
              aria-label="Planner query"
              value={query}
              rows={2}
              maxLength={500}
              onChange={(event) => setQuery(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === "Enter" && !event.shiftKey) {
                  event.preventDefault();
                  if (canRun) void run(query);
                }
              }}
            />
          </label>

          <ModelPicker catalog={catalog} selected={selected} onToggle={toggle} />

          <div className="planner__actions">
            <button className="planner__run" type="submit" disabled={!canRun}>
              Run
            </button>
            {running && <span className="planner__muted">Running, one model at a time…</span>}
          </div>
        </form>

        <details className="planner__examples">
          <summary>Try the {ADR_QUERIES.length} queries from ADR 0025</summary>
          <ul>
            {ADR_QUERIES.map((example) => (
              <li key={example}>
                <button
                  type="button"
                  className="chip"
                  disabled={running}
                  onClick={() => {
                    setQuery(example);
                    void run(example);
                  }}
                >
                  {example.length > 70 ? `${example.slice(0, 70)}…` : example}
                </button>
              </li>
            ))}
          </ul>
        </details>

        {runs.length > 0 && (
          <section className="planner__results" aria-label="Results">
            <h2 className="planner__query">
              <q>{asked}</q>
            </h2>
            {runs.map((entry) => (
              <ModelCard key={entry.model} run={entry} label={modelLabel(entry.model, models)} />
            ))}
            {finished && (
              <div className="planner__copy">
                <button type="button" className="planner__run" onClick={() => void copyResults()}>
                  Copy results as markdown
                </button>
                {copy === "copied" && <span className="planner__muted">Copied.</span>}
                {copy === "manual" && (
                  <textarea
                    className="planner__manual"
                    aria-label="Markdown results"
                    readOnly
                    rows={10}
                    value={markdown}
                    onFocus={(event) => event.currentTarget.select()}
                  />
                )}
              </div>
            )}
          </section>
        )}
      </main>
    </div>
  );
}

function ModelPicker({
  catalog,
  selected,
  onToggle,
}: {
  catalog: Catalog;
  selected: string[];
  onToggle: (name: string) => void;
}) {
  if (catalog.state === "loading") return <p className="planner__muted">Loading models…</p>;
  if (catalog.state === "error") {
    return (
      <p className="planner__error" role="alert">
        Could not list the Ollama models: {catalog.message}
      </p>
    );
  }

  const { models, default: defaultModel, warning } = catalog.data;
  const defaultMissing = !models.some((model) => model.name === defaultModel);

  return (
    <fieldset className="planner__models">
      <legend>Models (installed in Ollama)</legend>
      {models.length === 0 && <p className="planner__muted">No chat model is installed.</p>}
      {models.map((model) => (
        <label key={model.name} className="planner__model">
          <input
            type="checkbox"
            checked={selected.includes(model.name)}
            onChange={() => onToggle(model.name)}
          />
          <span>{model.name}</span>
          <span className="planner__muted">
            {formatGb(model.size_bytes)}
            {model.parameter_size ? `, ${model.parameter_size}` : ""}
          </span>
          {model.default && <span className="badge badge--good">default</span>}
          {thinkingHint(model.name) && (
            <span className="badge badge--partial">{thinkingHint(model.name)}</span>
          )}
          {model.loaded && <span className="badge badge--partial">in memory</span>}
        </label>
      ))}
      {defaultMissing && (
        <p className="planner__muted">
          The configured model ({defaultModel}) is not installed, so none is selected.
        </p>
      )}
      {selected.length > 1 && (
        <p className="planner__warning" role="status">
          {selected.length} models selected: they run one after another and Ollama keeps each in
          memory for a minute. Loading several large models on a 16 GB machine slows search.
        </p>
      )}
      {warning && (
        <p className="planner__warning" role="status">
          {warning}
        </p>
      )}
    </fieldset>
  );
}

function ModelCard({ run, label }: { run: ModelRun; label: string }) {
  return (
    <article className="planner__card" aria-label={`Result of ${run.model}`}>
      <header className="planner__card-head">
        <h3>{label}</h3>
        {run.state === "done" && <StatusBadge result={run.result} />}
      </header>
      {run.state === "waiting" && <p className="planner__muted">Waiting for its turn…</p>}
      {run.state === "running" && (
        <p className="planner__muted" role="status">
          Running… (a model that is not loaded yet needs time to load)
        </p>
      )}
      {run.state === "failed" && (
        <p className="planner__error" role="alert">
          Failed: {run.error}
        </p>
      )}
      {run.state === "done" && <ResultBody result={run.result} />}
    </article>
  );
}

function StatusBadge({ result }: { result: PlannerModelResult }) {
  const good = result.status === "ok" || result.status === "passthrough";
  return (
    <span className={`badge ${good ? "badge--good" : "badge--partial"}`}>{result.status}</span>
  );
}

function ResultBody({ result }: { result: PlannerModelResult }) {
  const [original = "", ...planned] = result.queries;
  const source = result.source;
  const extra = new Set(source?.only_planned ?? []);
  const warm =
    result.warm === null
      ? ""
      : result.warm
        ? " (model was loaded)"
        : " (includes loading the model)";

  return (
    <>
      <p className="planner__meta">
        Plan time <strong>{formatSeconds(result.plan_ms)}</strong>
        {warm}
        {source && (
          <>
            {" · "}Wikipedia <strong>{source.wiki_ms} ms</strong>
          </>
        )}
      </p>
      {result.detail && <p className="planner__warning">Planner said: {result.detail}</p>}

      <div className="planner__plan">
        <span className="chip chip--original" title="The query as typed is always searched first">
          {original}
        </span>
        {planned.map((query) => (
          <span className="chip" key={query}>
            {query}
          </span>
        ))}
        {planned.length === 0 && <span className="planner__muted">no planned queries</span>}
      </div>

      {source && (
        <div className="planner__columns">
          <section aria-label="Literal search found">
            <h4>Literal search found</h4>
            <TitleList titles={source.literal.titles} error={source.literal.error} />
          </section>
          <section aria-label="Planned searches also found">
            <h4>Planned searches also found</h4>
            <TitleList titles={plannedTitles(result)} extra={extra} />
            {source.searches
              .filter((search) => search.error)
              .map((search) => (
                <p className="planner__error" key={search.query}>
                  Search for {search.query} failed: {search.error}
                </p>
              ))}
          </section>
        </div>
      )}
    </>
  );
}

function TitleList({
  titles,
  error = null,
  extra = new Set<string>(),
}: {
  titles: string[];
  error?: string | null;
  extra?: Set<string>;
}) {
  if (error) return <p className="planner__error">Search failed: {error}</p>;
  if (titles.length === 0) return <p className="planner__muted">(nothing)</p>;
  return (
    <ul className="planner__titles">
      {titles.map((title) => (
        <li key={title}>{extra.has(title) ? <mark>{title}</mark> : title}</li>
      ))}
    </ul>
  );
}
