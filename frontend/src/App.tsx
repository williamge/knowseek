import { useCallback } from "react";
import { DocumentReader } from "./components/DocumentReader";
import { RecentDocuments } from "./components/RecentDocuments";
import { ResultsView } from "./components/ResultsView";
import { SearchBox } from "./components/SearchBox";
import { TopicsPage } from "./components/TopicsPage";
import { parseRoute, useRoute } from "./router";
import { DEFAULT_WATCH, useSearch, type WatchOptions } from "./lib/useSearch";
import { useTopics } from "./lib/useTopics";

export function App({ watch = DEFAULT_WATCH }: { watch?: WatchOptions }) {
  const [route, navigate] = useRoute();
  const topics = useTopics();
  const search = useSearch(route.page === "search" ? route.query : null, watch);

  const runSearch = useCallback(
    (query: string) => navigate({ page: "search", query, doc: null }),
    [navigate],
  );
  const openDocument = (doc: string) => navigate({ ...route, doc }, { state: { reader: true } });
  // Go back when the app opened the document, so the back button does not
  // reopen it. Replace the URL when the page was loaded with `?doc=`.
  const closeDocument = useCallback(() => {
    if ((window.history.state as { reader?: boolean } | null)?.reader) window.history.back();
    else navigate({ ...parseRoute(window.location), doc: null }, { replace: true });
  }, [navigate]);
  const home = route.page === "search" && !route.query;

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
          {topics.topics.length > 0 && (
            <nav className="chips" aria-label="Topics you follow">
              {topics.topics.slice(0, 8).map((topic) => (
                <button
                  key={topic.id}
                  type="button"
                  className="chip"
                  onClick={() => runSearch(topic.query)}
                >
                  {topic.query}
                </button>
              ))}
            </nav>
          )}
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
                navigate({ page: "search", query: null, doc: null });
              }}
            >
              knowseek
            </a>
            <SearchBox variant="compact" initialQuery={route.query ?? ""} onSearch={runSearch} />
          </header>
          <main className="page">
            {route.page === "topics" ? (
              <TopicsPage topics={topics} onSearch={runSearch} />
            ) : (
              <ResultsView state={search} topics={topics} onOpenDocument={openDocument} />
            )}
          </main>
        </>
      )}

      <nav className="corner-nav" aria-label="Main">
        <a
          href="/topics"
          aria-current={route.page === "topics" ? "page" : undefined}
          onClick={(event) => {
            event.preventDefault();
            navigate({ page: "topics", query: null, doc: null });
          }}
        >
          Topics{topics.topics.length > 0 && <span className="count">{topics.topics.length}</span>}
        </a>
      </nav>

      {route.doc && <DocumentReader id={route.doc} query={route.query} onClose={closeDocument} />}
    </div>
  );
}
