import { useCallback, useState } from "react";
import { DocumentReader } from "./components/DocumentReader";
import { RecentDocuments } from "./components/RecentDocuments";
import { ResultsView } from "./components/ResultsView";
import { SearchBox } from "./components/SearchBox";
import { parseRoute, useRoute } from "./router";
import { DEFAULT_WATCH, useSearch, type WatchOptions } from "./lib/useSearch";

export function App({ watch = DEFAULT_WATCH }: { watch?: WatchOptions }) {
  const [route, navigate] = useRoute();
  const [refreshKey, setRefreshKey] = useState(0);
  const search = useSearch(route.query, watch, refreshKey);

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
            <ResultsView state={search} onOpenDocument={openDocument} />
          </main>
        </>
      )}

      {route.doc && <DocumentReader id={route.doc} query={route.query} onClose={closeDocument} />}
    </div>
  );
}
