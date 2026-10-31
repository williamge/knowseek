# Knowseek web UI

Vite, React, and TypeScript. It uses only the JSON API in `backend/`.

```sh
make dev   # API, from the repository root
make web   # this app, on the API port + 1 (proxies /api to the API)
```

Without `make`: `API_PORT=4000 WEB_PORT=4001 npm run dev`.

| Command         | What it does                                    |
| --------------- | ----------------------------------------------- |
| `npm run dev`   | Dev server with the `/api` proxy                |
| `npm test`      | Vitest and Testing Library. `fetch` is stubbed. |
| `npm run check` | Types, Prettier, tests (part of `make check`)   |
| `npm run build` | Typecheck and production build to `dist/`       |

## Layout

- `src/App.tsx`: the home page, the results page, and the document reader.
- `src/router.ts`: state in the URL (`/?q=...&doc=...`).
- `src/api.ts`, `src/types.ts`: API client and response types.
- `src/lib/useSearch.ts`: runs a search. After a search that enqueued discovery, it polls for new documents and searches again.
- `test/`: tests and fixtures.

Press `/` to focus the search box. Press `Escape` to close a document.
