import { useEffect, useState } from "react";
import { api } from "../api";
import { displayHost, timeAgo } from "../lib/format";
import type { DocumentSummary } from "../types";

export function RecentDocuments({ onOpen }: { onOpen: (id: string) => void }) {
  const [documents, setDocuments] = useState<DocumentSummary[] | null>(null);

  useEffect(() => {
    const controller = new AbortController();
    api.listDocuments(controller.signal).then(setDocuments, () => setDocuments([]));
    return () => controller.abort();
  }, []);

  if (!documents || documents.length === 0) return null;

  return (
    <section className="recent" aria-labelledby="recent-heading">
      <h2 id="recent-heading">Recently learned</h2>
      <ul>
        {documents.slice(0, 6).map((doc) => (
          <li key={doc.id}>
            <button type="button" onClick={() => onOpen(doc.id)}>
              <span className="recent__title">{doc.title || displayHost(doc.url)}</span>
              <span className="recent__meta">
                {doc.source} · {timeAgo(doc.fetched_at)}
              </span>
            </button>
          </li>
        ))}
      </ul>
    </section>
  );
}
