import { useCallback, useState } from "react";
import { DocumentReader } from "./components/DocumentReader";
import { FactCard } from "./components/FactCard";
import { RecentDocuments } from "./components/RecentDocuments";
import { ResultsView } from "./components/ResultsView";
import { SearchBox } from "./components/SearchBox";
import { parseRoute, useRoute } from "./router";
import { DEFAULT_WATCH, useSearch, type WatchOptions } from "./lib/useSearch";
import { DEFAULT_CARD_POLLING, useCard, type CardPolling } from "./lib/useCard";

export function App({
  watch = DEFAULT_WATCH,
  cardPolling = DEFAULT_CARD_POLLING,
}: {
  watch?: WatchOptions;
  cardPolling?: CardPolling;
}) {
  const [route, navigate] = useRoute();
  const [refreshKey, setRefreshKey] = useState(0);
  const search = useSearch(route.query, watch, refreshKey);
  // The card has its own state and requests: the results never wait for it.
  const card = useCard(route.query, cardPolling);

  // The URL does not change when the user searches for the same query again
  // (for example to see what discovery added), so run the search again here.
  const runSearch = useCallback(
    (query: string) => {
      if (route.query === query && !route.doc) {
        setRefreshKey((key) => key + 1);
      } else {
        navigate({ query, doc: null });
      }
    },
    [navigate, route],
  );
  const openDocument = (doc: string) => navigate({ ...route, doc }, { state: { reader: true } });
  // Go back when the app opened the document, so the back button does not
  // reopen it. Replace the URL when the page was loaded with `?doc=`.
  const closeDocument = useCallback(() => {
    if ((window.history.state as { reader?: boolean } | null)?.reader) window.history.back();
    else navigate({ ...parseRoute(window.location), doc: null }, { replace: true });
  }, [navigate]);
  const home = !route.query;

  return (
    <div className={`app${home ? " app--home" : ""}`}>
      {home ? (
        <main className="hero">
          <h1 className="wordmark">knowseek</h1>
          <p className="tagline">
            Ask anything. If Knowseek does not know yet, it goes and finds out.
          </p>
          <SearchBox variant="hero" onSearch={runSearch} autoFocus />
          <p className="hint">
            <kbd>Enter</kbd> to search · <kbd>Shift</kbd>+<kbd>Enter</kbd> for a new line
          </p>
          <RecentDocuments onOpen={openDocument} />
        </main>
      ) : (
        <>
          <header className="topbar">
            <a
              className="wordmark wordmark--small"
              href="/"
              onClick={(event) => {
                event.preventDefault();
                navigate({ query: null, doc: null });
              }}
            >
              knowseek
            </a>
            <SearchBox variant="compact" initialQuery={route.query ?? ""} onSearch={runSearch} />
          </header>
          <main className="page">
            {card && <FactCard data={card} onSearch={runSearch} />}
            <ResultsView state={search} onOpenDocument={openDocument} />
          </main>
        </>
      )}

      {route.doc && <DocumentReader id={route.doc} query={route.query} onClose={closeDocument} />}
    </div>
  );
}
