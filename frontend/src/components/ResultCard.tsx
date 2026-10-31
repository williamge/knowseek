import { useState } from "react";
import {
  displayHost,
  isWebUrl,
  shortDate,
  timeAgo,
  type CardPassage,
  type HitGroup,
} from "../lib/format";
import { Highlighted } from "./Highlighted";

interface Props {
  group: HitGroup;
  query: string;
  fresh: boolean;
  onOpen: (documentId: string) => void;
}

export function ResultCard({ group, query, fresh, onOpen }: Props) {
  const [expanded, setExpanded] = useState(false);
  const [best, ...more] = group.passages;
  const passages = expanded ? group.passages : [best];

  return (
    <article
      className={`result${fresh ? " result--fresh" : ""}${expanded ? " result--expanded" : ""}`}
    >
      <div className="result__meta">
        <span className="result__host">{displayHost(group.url)}</span>
        <span aria-hidden="true">·</span>
        <time dateTime={group.fetchedAt} title={new Date(group.fetchedAt).toLocaleString()}>
          fetched {timeAgo(group.fetchedAt)}
        </time>
        {group.sourceUpdatedAt && (
          <>
            <span aria-hidden="true">·</span>
            <time
              dateTime={group.sourceUpdatedAt}
              title={`Last edited at the source: ${new Date(group.sourceUpdatedAt).toLocaleString()}`}
            >
              edited {shortDate(group.sourceUpdatedAt)}
            </time>
          </>
        )}
        {fresh && <span className="result__new">new</span>}
      </div>

      <h2 className="result__title">
        <button type="button" onClick={() => onOpen(group.documentId)}>
          {group.title}
        </button>
        {isWebUrl(group.url) && (
          <a
            className="result__external"
            href={group.url}
            target="_blank"
            rel="noreferrer"
            aria-label={`Open ${group.title} on ${displayHost(group.url)}`}
          >
            ↗
          </a>
        )}
      </h2>

      {passages.map((passage) => (
        <p key={passage.chunk_id} className="result__passage" title={matchedBy(passage)}>
          <Highlighted text={passage.content} query={query} />
        </p>
      ))}

      {more.length > 0 && (
        <button type="button" className="link-button" onClick={() => setExpanded(!expanded)}>
          {expanded
            ? "Show fewer passages"
            : `Show ${more.length} more ${more.length === 1 ? "passage" : "passages"}`}
        </button>
      )}
    </article>
  );
}

function matchedBy(hit: CardPassage): string {
  const parts = [];
  if (hit.keyword_rank) parts.push(`keyword rank ${hit.keyword_rank}`);
  if (hit.semantic_rank) parts.push(`semantic rank ${hit.semantic_rank}`);
  if (hit.similarity !== null) parts.push(`similarity ${hit.similarity.toFixed(2)}`);
  const by = parts.length > 0 ? `Matched by ${parts.join(", ")}. ` : "";
  return `${by}Score ${hit.score.toFixed(4)}.`;
}
