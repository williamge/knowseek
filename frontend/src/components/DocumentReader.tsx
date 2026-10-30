import { useEffect, useRef, useState } from "react";
import { api } from "../api";
import { displayHost, isWebUrl, timeAgo } from "../lib/format";
import type { KnowseekDocument } from "../types";
import { Highlighted } from "./Highlighted";

interface Props {
  id: string;
  query: string | null;
  onClose: () => void;
}

type State =
  | { status: "loading" }
  | { status: "error"; error: string }
  | { status: "done"; document: KnowseekDocument };

export function DocumentReader({ id, query, onClose }: Props) {
  const [state, setState] = useState<State>({ status: "loading" });
  const closeRef = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    const controller = new AbortController();
    setState({ status: "loading" });
    api.getDocument(id, controller.signal).then(
      (document) => setState({ status: "done", document }),
      (error: Error) => {
        if (!controller.signal.aborted) setState({ status: "error", error: error.message });
      },
    );
    return () => controller.abort();
  }, [id]);

  useEffect(() => {
    closeRef.current?.focus();
    const onKeyDown = (event: KeyboardEvent) => event.key === "Escape" && onClose();
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [onClose]);

  const title = state.status === "done" ? state.document.title || "Untitled" : "Document";

  return (
    <div className="reader-backdrop" onClick={onClose}>
      <aside
        className="reader"
        role="dialog"
        aria-modal="true"
        aria-label={title}
        onClick={(event) => event.stopPropagation()}
      >
        <button ref={closeRef} type="button" className="reader__close" onClick={onClose}>
          <span aria-hidden="true">×</span>
          <span className="visually-hidden">Close</span>
        </button>

        {state.status === "loading" && <p className="muted">Loading…</p>}
        {state.status === "error" && (
          <div className="notice notice--error" role="alert">
            {state.error}
          </div>
        )}
        {state.status === "done" && <DocumentBody document={state.document} query={query} />}
      </aside>
    </div>
  );
}

function DocumentBody({ document, query }: { document: KnowseekDocument; query: string | null }) {
  const paragraphs = document.body.split(/\n\s*\n/).filter((p) => p.trim() !== "");

  return (
    <article className="reader__doc">
      <p className="reader__meta">
        <span className="tag">{document.source}</span>
        {isWebUrl(document.url) ? (
          <a href={document.url} target="_blank" rel="noreferrer">
            {displayHost(document.url)} ↗
          </a>
        ) : (
          <span>{displayHost(document.url)}</span>
        )}
        <span>fetched {timeAgo(document.fetched_at)}</span>
        {document.published_at && (
          <span>published {new Date(document.published_at).toLocaleDateString()}</span>
        )}
      </p>
      <h1>{document.title || "Untitled"}</h1>
      {paragraphs.map((paragraph, index) => (
        <p key={index}>{query ? <Highlighted text={paragraph} query={query} /> : paragraph}</p>
      ))}
    </article>
  );
}
