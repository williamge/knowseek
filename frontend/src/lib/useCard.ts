import { useEffect, useState } from "react";
import { api } from "../api";
import type { CardResponse } from "../types";

export interface CardPolling {
  /** Time between two requests while the server has nothing cached yet. */
  pendingMs: number;
  /** Stop asking for a card that is still pending after this time. */
  pendingTimeoutMs: number;
  /** The server says when to ask again; the delay is kept within these limits. */
  minMs: number;
  maxMs: number;
  /** Delays before each retry after `unavailable` or a failed request, then give up. */
  retryDelaysMs: number[];
}

export const DEFAULT_CARD_POLLING: CardPolling = {
  pendingMs: 700,
  pendingTimeoutMs: 30_000,
  minMs: 2000,
  maxMs: 60_000,
  retryDelaysMs: [5000, 15_000, 30_000],
};

/**
 * The card of live facts for a query, kept up to date, or `null` when there
 * is nothing to show (no card yet, none for this query, or the source is
 * down and nothing was ever loaded).
 *
 * It polls `GET /api/cards?q=` (cache-only on the server):
 *
 *   - `pending`: every `pendingMs`, up to `pendingTimeoutMs`.
 *   - `fresh`, `stale`: after `refresh_after_ms` from the response (the server
 *     derives it from the TTL: about 15 s for a live game, 2 s while stale),
 *     within `minMs`..`maxMs`. A card that was shown stays on screen while a
 *     request fails, with its "as of" time. A card that was fresh and turns
 *     stale is shown as fresh until the next response says stale again: the
 *     refresh that makes it stale finishes in a second, and the notice would
 *     flash on every refresh of a live game. A refresh that failed stays stale.
 *   - `none`: stops at once. The server caches "no card for this" for a day, so
 *     asking again changes nothing.
 *   - `unavailable` and failed requests: retried after each of `retryDelaysMs`,
 *     then it stops until the query changes.
 *
 * Nothing is requested while the tab is hidden. When it is visible again,
 * the card is requested at once. It never blocks the search: the page
 * renders the results whatever this returns.
 */
export function useCard(
  query: string | null,
  polling: CardPolling = DEFAULT_CARD_POLLING,
): CardResponse | null {
  const [shown, setShown] = useState<{ query: string; data: CardResponse } | null>(null);
  const { pendingMs, pendingTimeoutMs, minMs, maxMs, retryDelaysMs } = polling;
  const retryKey = retryDelaysMs.join(",");

  useEffect(() => {
    setShown(null);
    if (!query) return;

    const controller = new AbortController();
    const { signal } = controller;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let paused = false;
    let stopped = false;
    let pendingSince: number | null = null;
    let failures = 0;
    let previous: CardResponse["status"] | null = null;

    const schedule = (ms: number) => {
      clearTimeout(timer);
      if (document.hidden) paused = true;
      else timer = setTimeout(wake, ms);
    };

    // A timer can fire in a tab that became hidden without telling us.
    const wake = () => {
      if (document.hidden) paused = true;
      else void poll();
    };

    const retryOrStop = () => {
      const delay = retryDelaysMs[failures];
      failures += 1;
      if (delay === undefined) stopped = true;
      else schedule(delay);
    };

    async function poll() {
      paused = false;
      try {
        const data = await api.getCard(query!, signal);
        if (signal.aborted) return;
        handle(data);
      } catch {
        if (signal.aborted) return;
        retryOrStop();
      }
    }

    const handle = (data: CardResponse) => {
      switch (data.status) {
        case "pending": {
          pendingSince ??= Date.now();
          if (Date.now() - pendingSince >= pendingTimeoutMs) stopped = true;
          else schedule(pendingMs);
          return;
        }
        case "fresh":
        case "stale": {
          failures = 0;
          pendingSince = null;
          if (data.card) {
            // The first stale response after a fresh one is the refresh in progress.
            const refreshing = data.status === "stale" && previous === "fresh";
            setShown({ query: query!, data: refreshing ? { ...data, status: "fresh" } : data });
          }
          previous = data.status;
          schedule(Math.min(Math.max(data.refresh_after_ms, minMs), maxMs));
          return;
        }
        case "none": {
          setShown(null);
          stopped = true;
          return;
        }
        case "unavailable": {
          pendingSince = null;
          retryOrStop();
          return;
        }
      }
    };

    const onVisibilityChange = () => {
      if (stopped) return;
      if (document.hidden) {
        // Pause: the timer may be waiting. A request in flight finishes, and
        // `schedule` then sees the hidden tab.
        clearTimeout(timer);
        paused = true;
      } else if (paused) {
        void poll();
      }
    };
    document.addEventListener("visibilitychange", onVisibilityChange);

    void poll();

    return () => {
      controller.abort();
      clearTimeout(timer);
      document.removeEventListener("visibilitychange", onVisibilityChange);
    };
  }, [query, pendingMs, pendingTimeoutMs, minMs, maxMs, retryKey]);

  return shown && shown.query === query ? shown.data : null;
}
