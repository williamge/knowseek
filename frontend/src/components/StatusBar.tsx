import type { SearchState } from "../lib/useSearch";
import type { Coverage } from "../types";

type Done = Extract<SearchState, { status: "done" }>;

const COVERAGE: Record<Coverage, { label: string; className: string }> = {
  sufficient: { label: "Well covered", className: "badge--good" },
  partial: { label: "Partly covered", className: "badge--partial" },
  none: { label: "Not covered yet", className: "badge--none" },
};

export function StatusBar({ state }: { state: Done }) {
  const { result, watching, discovered } = state;
  const coverage = COVERAGE[result.coverage];

  return (
    <div className="status">
      <span className={`badge ${coverage.className}`}>{coverage.label}</span>
      <span className="status__text" role="status" aria-live="polite">
        {discoveryText(state)}
      </span>
      {watching && <span className="spinner" aria-hidden="true" />}
      {!watching && discovered > 0 && (
        <span className="status__added">
          Added {discovered} new {discovered === 1 ? "source" : "sources"}
        </span>
      )}
    </div>
  );
}

function discoveryText({ result, watching, discovered }: Done): string {
  const sources = new Set(result.hits.map((hit) => hit.document_id)).size;
  const found =
    sources === 0
      ? "Nothing in the index yet."
      : `${sources} ${sources === 1 ? "source" : "sources"} in the index.`;

  switch (result.discovery.status) {
    case "not_needed":
      return found;
    case "error":
      return `${found} Could not start the search for new sources.`;
    case "enqueued":
      if (watching) return `${found} Looking for new sources…`;
      if (discovered > 0) return found;
      return `${found} The search for new sources continues in the background. Try again later.`;
  }
}
