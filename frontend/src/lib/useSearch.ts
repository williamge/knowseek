import { useEffect, useState } from "react";
import { api, rateLimitDelayMs } from "../api";
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

/** A search that is answered with 429 is asked again this many times, then it fails. */
export const MAX_RATE_LIMIT_RETRIES = 3;

export type SearchState =
  | { status: "idle" }
  | { status: "loading"; query: string }
  /** Too many requests: the search is asked again after `Retry-After` (not an error). */
  | { status: "rate_limited"; query: string; retryAfterMs: number }
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
    let retryTimer: ReturnType<typeof setTimeout> | undefined;
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
      let nextCheckMs = intervalMs;

      const check = async () => {
        try {
          const docs = await api.listDocuments(signal);
          const added = docs.filter((doc) => !known.has(doc.id));
          nextCheckMs = intervalMs;

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
        } catch (error) {
          if (signal.aborted) return;
          // A failed check is not fatal. Try again on the next tick, or, when
          // the server said "too many requests", after its `Retry-After`. The
          // results on screen stay.
          nextCheckMs = rateLimitDelayMs(error) ?? intervalMs;
        }

        if (signal.aborted) return;
        if (Date.now() >= deadline || quiet >= quietChecks) {
          update((s) => ({ ...s, watching: false }));
          return;
        }
        timer = setTimeout(check, nextCheckMs);
      };

      timer = setTimeout(check, intervalMs);
    };

    (async () => {
      // Read the baseline before the search starts, so a document that
      // arrives while the search runs still counts as new.
      const baseline = await api.listDocuments(signal).catch(() => null);

      for (let rateLimited = 0; ; rateLimited += 1) {
        try {
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
          return;
        } catch (error) {
          if (signal.aborted) return;
          const retryAfterMs = rateLimitDelayMs(error);
          if (retryAfterMs === null || rateLimited >= MAX_RATE_LIMIT_RETRIES) {
            setState({
              status: "error",
              query,
              error: error instanceof Error ? error.message : String(error),
            });
            return;
          }
          // Not an error yet: say so quietly, wait as the server asked, ask again.
          setState({ status: "rate_limited", query, retryAfterMs });
          await new Promise<void>((resolve) => {
            retryTimer = setTimeout(resolve, retryAfterMs);
          });
          if (signal.aborted) return;
        }
      }
    })();

    return () => {
      controller.abort();
      clearTimeout(timer);
      clearTimeout(retryTimer);
    };
  }, [query, refreshKey, intervalMs, timeoutMs, quietChecks]);

  return state;
}
