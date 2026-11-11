import { routeToUrl, type Navigate, type Page } from "../router";

const LINKS: { page: Page; label: string }[] = [{ page: "stats", label: "Stats" }];

/** Links to the pages other than search, at the bottom of every page. */
export function SiteNav({ current, navigate }: { current: Page | null; navigate: Navigate }) {
  return (
    <nav className="site-nav" aria-label="More pages">
      {LINKS.map(({ page, label }) => (
        <a
          key={page}
          href={routeToUrl({ page, query: null, doc: null })}
          aria-current={current === page ? "page" : undefined}
          onClick={(event) => {
            event.preventDefault();
            navigate({ page, query: null, doc: null });
          }}
        >
          {label}
        </a>
      ))}
    </nav>
  );
}
