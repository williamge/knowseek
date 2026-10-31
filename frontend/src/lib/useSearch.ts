import { useEffect, useState } from "react";
import { api } from "../api";
import type { DocumentSummary, SearchResult } from "../types";

export interface WatchOptions {
  /** Time between two checks for new documents. */
  intervalMs: number;
  /** Stop watching after this time, also when nothing arrived. */
  timeoutMs: number;
  /** After new documents arrived, stop after this many checks with nothing new. */
  quietChecks: number;
}

export const DEFAULT_WATCH: WatchOptions = { intervalMs: 3000, timeoutMs: 90_000, quietChecks: 3 };

export type SearchState =
  | { status: "idle" }
  | { status: "loading"; query: string }
  | { status: "error"; query: string; error: string }
  | {
      status: "done";
      query: string;
      result: SearchResult;
      /** True while the page watches for documents that discovery adds. */
      watching: boolean;
      /** Number of documents that discovery added since the search. */
      discovered: number;
      /** Documents that were not in the first result. */
      freshDocumentIds: ReadonlySet<string>;
    };

/**
 * Runs a search. When the search enqueues discovery, it watches the index
 * for new documents and runs the search again when they arrive.
 *
 * The API cannot tell us when a discovery job finishes yet (task 006), so
 * this checks `GET /api/documents` for new document ids. That call has no
 * side effects. Each new search can enqueue discovery again, so the number
 * of new searches is limited by `quietChecks` and `timeoutMs`.
 */
export function useSearch(
  query: string | null,
  watch: WatchOptions = DEFAULT_WATCH,
  /** Change this value to run the same query again. */
  refreshKey = 0,
): SearchState {
  const [state, setState] = useState<SearchState>({ status: "idle" });
  const { intervalMs, timeoutMs, quietChecks } = watch;

  useEffect(() => {
    if (!query) {
      setState({ status: "idle" });
      return;
    }

    const controller = new AbortController();
    const { signal } = controller;
    let timer: ReturnType<typeof setTimeout> | undefined;
    setState({ status: "loading", query });

    const update = (fn: (state: Extract<SearchState, { status: "done" }>) => SearchState) =>
      setState((current) =>
        current.status === "done" && current.query === query ? fn(current) : current,
      );

    const watchDiscovery = (first: SearchResult, baseline: DocumentSummary[]) => {
      const known = new Set(baseline.map((doc) => doc.id));
      const firstDocuments = new Set(first.hits.map((hit) => hit.document_id));
      const deadline = Date.now() + timeoutMs;
      let discovered = 0;
      let quiet = 0;

      const check = async () => {
        try {
          const docs = await api.listDocuments(signal);
          const added = docs.filter((doc) => !known.has(doc.id));

          if (added.length > 0) {
            // Mark the documents as seen only after the search worked. If it
            // fails, the next check finds the same documents again.
            const result = await api.search(query, { signal });
            added.forEach((doc) => known.add(doc.id));
            discovered += added.length;
            quiet = 0;
            const freshDocumentIds = new Set(
              result.hits.map((hit) => hit.document_id).filter((id) => !firstDocuments.has(id)),
            );
            const watching = result.coverage !== "sufficient";
            update((s) => ({ ...s, result, discovered, freshDocumentIds, watching }));
            if (!watching) return;
          } else if (discovered > 0) {
            quiet += 1;
          }
        } catch {
          if (signal.aborted) return;
          // A failed check is not fatal. Try again on the next tick.
        }

        if (signal.aborted) return;
        if (Date.now() >= deadline || quiet >= quietChecks) {
          update((s) => ({ ...s, watching: false }));
          return;
        }
        timer = setTimeout(check, intervalMs);
      };

      timer = setTimeout(check, intervalMs);
    };

    (async () => {
      try {
        // Read the baseline before the search starts, so a document that
        // arrives while the search runs still counts as new.
        const baseline = await api.listDocuments(signal).catch(() => null);
        const result = await api.search(query, { signal });
        const watching = result.discovery.status === "enqueued" && baseline !== null;
        setState({
          status: "done",
          query,
          result,
          watching,
          discovered: 0,
          freshDocumentIds: new Set(),
        });
        if (watching) watchDiscovery(result, baseline);
      } catch (error) {
        if (signal.aborted) return;
        setState({
          status: "error",
          query,
          error: error instanceof Error ? error.message : String(error),
        });
      }
    })();

    return () => {
      controller.abort();
      clearTimeout(timer);
    };
  }, [query, refreshKey, intervalMs, timeoutMs, quietChecks]);

  return state;
}
