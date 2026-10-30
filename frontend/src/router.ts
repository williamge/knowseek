import { useCallback, useEffect, useState } from "react";
import { flushSync } from "react-dom";

/**
 * The app state that lives in the URL, so searches can be shared and the
 * back button works.
 *
 *   /                 home
 *   /?q=rust+async    search results
 *   /?q=...&doc=ID    search results with a document open
 *   /topics           followed topics
 */
export interface Route {
  page: "search" | "topics";
  query: string | null;
  doc: string | null;
}

export function parseRoute(location: { pathname: string; search: string }): Route {
  const params = new URLSearchParams(location.search);
  const page = location.pathname.replace(/\/+$/, "") === "/topics" ? "topics" : "search";
  const query = params.get("q")?.trim() || null;
  return { page, query: page === "search" ? query : null, doc: params.get("doc") || null };
}

export function routeToUrl(route: Route): string {
  const params = new URLSearchParams();
  if (route.page === "search" && route.query) params.set("q", route.query);
  if (route.doc) params.set("doc", route.doc);
  const search = params.toString();
  return (route.page === "topics" ? "/topics" : "/") + (search ? `?${search}` : "");
}

export interface NavigateOptions {
  replace?: boolean;
  /** Stored as `history.state`. */
  state?: unknown;
}

export type Navigate = (route: Route, opts?: NavigateOptions) => void;

export function useRoute(): [Route, Navigate] {
  const [route, setRoute] = useState(() => parseRoute(window.location));

  useEffect(() => {
    const onPopState = () => setRoute(parseRoute(window.location));
    window.addEventListener("popstate", onPopState);
    return () => window.removeEventListener("popstate", onPopState);
  }, []);

  const navigate = useCallback<Navigate>((next, opts = {}) => {
    const url = routeToUrl(next);
    if (url === window.location.pathname + window.location.search) return;
    const current = parseRoute(window.location);
    if (opts.replace) window.history.replaceState(opts.state ?? null, "", url);
    else window.history.pushState(opts.state ?? null, "", url);

    // Animate page changes (for example the search box that moves from the
    // middle of the screen to the top) where the browser supports it.
    const update = () => flushSync(() => setRoute(parseRoute(window.location)));
    const pageChanged = next.page !== current.page || next.query !== current.query;
    if (document.startViewTransition && pageChanged) document.startViewTransition(update);
    else update();
  }, []);

  return [route, navigate];
}
