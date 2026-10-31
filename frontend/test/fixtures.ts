import type { Hit, KnowseekDocument, SearchResult } from "../src/types";

export function hit(overrides: Partial<Hit> = {}): Hit {
  return {
    document_id: "doc-1",
    chunk_id: "chunk-1",
    url: "https://example.com/one",
    title: "Doc one",
    content: "Octopuses have nine brains.",
    published_at: null,
    fetched_at: new Date().toISOString(),
    score: 0.03,
    keyword_rank: 1,
    semantic_rank: 1,
    similarity: 0.8,
    passages: [],
    ...overrides,
  };
}

export function result(overrides: Partial<SearchResult> = {}): SearchResult {
  return {
    query: "octopus",
    coverage: "sufficient",
    discovery: { status: "not_needed" },
    hits: [hit()],
    ...overrides,
  };
}

export function document(overrides: Partial<KnowseekDocument> = {}): KnowseekDocument {
  return {
    id: "doc-1",
    url: "https://example.com/one",
    title: "Doc one",
    body: "First paragraph.\n\nSecond paragraph about octopus.",
    source: "wikipedia",
    published_at: null,
    fetched_at: new Date().toISOString(),
    metadata: {},
    ...overrides,
  };
}

/** Routes `fetch` calls by "METHOD /path". Unknown routes fail the test. */
export function mockApi(routes: Record<string, (body: unknown) => unknown | Response>) {
  const calls: { key: string; body: unknown }[] = [];
  const spy = vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const path = String(input).replace(/^\/api/, "");
    const key = `${init?.method ?? "GET"} ${path}`;
    const body = init?.body ? JSON.parse(String(init.body)) : undefined;
    calls.push({ key, body });
    const handler = routes[key];
    if (!handler) throw new Error(`Unexpected request: ${key}`);
    const value = handler(body);
    if (value instanceof Response) return value;
    return new Response(JSON.stringify({ data: value }), { status: 200 });
  });
  return { calls, spy };
}
