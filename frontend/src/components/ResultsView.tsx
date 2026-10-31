import { groupHits } from "../lib/format";
import type { SearchState } from "../lib/useSearch";
import type { TopicsApi } from "../lib/useTopics";
import { FollowButton } from "./FollowButton";
import { ResultCard } from "./ResultCard";
import { StatusBar } from "./StatusBar";

interface Props {
  state: SearchState;
  topics: TopicsApi;
  onOpenDocument: (id: string) => void;
}

export function ResultsView({ state, topics, onOpenDocument }: Props) {
  if (state.status === "idle") return null;

  if (state.status === "loading") {
    return (
      <section className="results" aria-busy="true">
        {[0, 1, 2].map((i) => (
          <div key={i} className="result result--skeleton" aria-hidden="true">
            <div />
            <div />
            <div />
          </div>
        ))}
      </section>
    );
  }

  if (state.status === "error") {
    return (
      <section className="results">
        <div className="notice notice--error" role="alert">
          <strong>The search failed.</strong> {state.error}
        </div>
      </section>
    );
  }

  const groups = groupHits(state.result.hits);
  const freshDocs = state.freshDocumentIds;

  return (
    <section className="results">
      <div className="results__header">
        <StatusBar state={state} />
        <FollowButton query={state.query} topics={topics} />
      </div>

      {groups.length === 0 ? (
        <div className="notice">
          <p>
            <strong>Nothing in the index matches this yet.</strong>
          </p>
          <p>
            {state.watching
              ? "Knowseek is looking for sources now. Results appear here when they arrive."
              : "Follow the topic to have Knowseek check for new data every day."}
          </p>
        </div>
      ) : (
        groups.map((group) => (
          <ResultCard
            key={group.documentId}
            group={group}
            query={state.query}
            fresh={freshDocs.has(group.documentId)}
            onOpen={onOpenDocument}
          />
        ))
      )}
    </section>
  );
}
