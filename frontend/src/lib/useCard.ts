import { useEffect, useState } from "react";
import { api, rateLimitDelayMs } from "../api";
import type { CardResponse } from "../types";

export interface CardPolling {
  /** Time between two requests while the server has nothing cached yet. */
  pendingMs: number;
  /** After this long pending, the card is polled at the slow cadence. */
  pendingTimeoutMs: number;
  /** The server says when to ask again; the delay is kept within these limits. */
  minMs: number;
  maxMs: number;
  /** Delays before each retry after `unavailable` or a failed request. */
  retryDelaysMs: number[];
  /**
   * After the retries, and after a long pending, ask at least this often for
   * as long as the tab is visible. The server may be back by then.
   */
  slowMs: number;
}

/**
 * How long the server does not retry a failed Wikidata call
 * (`backoff` of `Knowseek.Entities` in `backend/config/config.exs`). The
 * entity of a query that failed to resolve stays `unavailable` that long, so
 * the retries below must outlast it, or all of them land inside the backoff.
 * (A `Retry-After` from Wikidata can make it longer, up to 10 minutes; the
 * slow cadence covers that.)
 */
export const ENTITY_BACKOFF_MS = 60_000;

export const DEFAULT_CARD_POLLING: CardPolling = {
  pendingMs: 700,
  pendingTimeoutMs: 30_000,
  minMs: 2000,
  maxMs: 60_000,
  // Cumulative: 5, 20, 50, 110 and 200 s after the first failure.
  retryDelaysMs: [5000, 15_000, 30_000, 60_000, 90_000],
  slowMs: 30_000,
};

/**
 * The card of live facts for a query, kept up to date, or `null` when there
 * is nothing to show (no card yet, none for this query, or the source is
 * down and nothing was ever loaded).
 *
 * It polls `GET /api/cards?q=` (cache-only on the server):
 *
 *   - `pending`: every `pendingMs`; after `pendingTimeoutMs` at the slow
 *     cadence (the server may be busy: it drops refreshes over its cap).
 *   - `fresh`, `stale`: after `refresh_after_ms` from the response (the server
 *     derives it from the TTL: about 15 s for a live game, 2 s while stale),
 *     within `minMs`..`maxMs`. A card that was fresh and turns stale is shown
 *     as fresh until the next response says stale again: the refresh that
 *     makes it stale finishes in a second, and the notice would flash on
 *     every refresh of a live game. A refresh that failed stays stale.
 *   - HTTP 429 (this client asked too often): the next request waits for the
 *     server's `Retry-After` (1-60 s). The card on screen stays, and nothing
 *     is shown: the retries and the stale mark below are for a source that is down.
 *   - `none`: stops at once. The server caches "no card for this" for a day, so
 *     asking again changes nothing.
 *   - `unavailable` and failed requests: retried after each of `retryDelaysMs`
 *     (they outlast `ENTITY_BACKOFF_MS`). When the retries are used up, a
 *     card on screen is marked stale ("may be out of date"), and the card is
 *     polled every `slowMs` (or the server's `refresh_after_ms` if longer),
 *     so it recovers when the source does.
 *
 * Nothing is requested while the tab is hidden. When it is visible again, or
 * the browser comes back online, the card is requested at once (unless a
 * request is already running: there is one at a time). It never blocks the
 * search: the page renders the results whatever this returns.
 */
export function useCard(
  query: string | null,
  polling: CardPolling = DEFAULT_CARD_POLLING,
): CardResponse | null {
  const [shown, setShown] = useState<{ query: string; data: CardResponse } | null>(null);
  const { pendingMs, pendingTimeoutMs, minMs, maxMs, retryDelaysMs, slowMs } = polling;
  const retryKey = retryDelaysMs.join(",");

  useEffect(() => {
    setShown(null);
    if (!query) return;

    const controller = new AbortController();
    const { signal } = controller;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let paused = false;
    let stopped = false;
    let inFlight = false;
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

    // The card on screen is the last one that loaded: say so when the source
    // stays down.
    const markStale = () => {
      previous = "stale";
      setShown((current) =>
        current && current.query === query && current.data.status === "fresh"
          ? { ...current, data: { ...current.data, status: "stale" } }
          : current,
      );
    };

    const retryOrSlow = (serverMs: number) => {
      const delay = retryDelaysMs[failures];
      failures += 1;
      if (delay !== undefined) {
        schedule(delay);
      } else {
        markStale();
        schedule(Math.max(slowMs, serverMs));
      }
    };

    async function poll() {
      if (inFlight) return;
      inFlight = true;
      paused = false;
      try {
        const data = await api.getCard(query!, signal);
        if (signal.aborted) return;
        handle(data);
      } catch (error) {
        if (signal.aborted) return;
        const limitedMs = rateLimitDelayMs(error);
        // Too many requests is not a failure of the source: wait as long as
        // the server says, keep the card, and do not use up the retries.
        if (limitedMs !== null) schedule(limitedMs);
        else retryOrSlow(0);
      } finally {
        inFlight = false;
      }
    }

    const handle = (data: CardResponse) => {
      switch (data.status) {
        case "pending": {
          pendingSince ??= Date.now();
          if (Date.now() - pendingSince >= pendingTimeoutMs) {
            schedule(slowMs);
          } else {
            schedule(pendingMs);
          }
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
          retryOrSlow(data.refresh_after_ms);
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

    const onOnline = () => {
      if (stopped || document.hidden || inFlight) return;
      clearTimeout(timer);
      void poll();
    };

    document.addEventListener("visibilitychange", onVisibilityChange);
    window.addEventListener("online", onOnline);

    void poll();

    return () => {
      controller.abort();
      clearTimeout(timer);
      document.removeEventListener("visibilitychange", onVisibilityChange);
      window.removeEventListener("online", onOnline);
    };
  }, [query, pendingMs, pendingTimeoutMs, minMs, maxMs, slowMs, retryKey]);

  return shown && shown.query === query ? shown.data : null;
}
