import type {
  CardEntity,
  CardResponse,
  Hit,
  KnowseekDocument,
  SearchResult,
  SportsTeamFacts,
} from "../src/types";

export const knicksEntity: CardEntity = {
  id: "Q131364",
  label: "New York Knicks",
  description: "National Basketball Association team in New York City",
  kind: "sports_team",
  wikipedia_title: "New York Knicks",
};

export const westchesterEntity: CardEntity = {
  id: "Q15927936",
  label: "Westchester Knicks",
  description: "basketball team",
  kind: "sports_team",
  wikipedia_title: "Westchester Knicks",
};

export function teamFacts(overrides: Partial<SportsTeamFacts> = {}): SportsTeamFacts {
  return {
    source: "ESPN",
    league: "NBA",
    record: "2-4",
    live: null,
    last_game: {
      date: "2026-10-30T23:30:00Z",
      opponent: "Philadelphia 76ers",
      home_away: "away",
      result: "L",
      team_score: 93,
      opponent_score: 98,
    },
    next_game: { date: "2026-11-03T00:30:00Z", opponent: "Brooklyn Nets", home_away: "home" },
    injuries: [{ player: "Jose Alvarado", status: "Out" }],
    ...overrides,
  };
}

/** A response of `GET /api/cards`. The default is a fresh Knicks card. */
export function cardResponse(overrides: Partial<CardResponse> = {}): CardResponse {
  return {
    status: "fresh",
    entity: knicksEntity,
    alternatives: [westchesterEntity],
    card: { type: "sports_team", title: "New York Knicks", facts: teamFacts() },
    as_of: "2026-10-31T15:42:15Z",
    refresh_after_ms: 60_000,
    ...overrides,
  };
}

/** What the API says when it has nothing for a query: no card. */
export function noCard(overrides: Partial<CardResponse> = {}): CardResponse {
  return cardResponse({
    status: "none",
    entity: null,
    alternatives: [],
    card: null,
    as_of: null,
    refresh_after_ms: 60_000,
    ...overrides,
  });
}

export function hit(overrides: Partial<Hit> = {}): Hit {
  return {
    document_id: "doc-1",
    chunk_id: "chunk-1",
    url: "https://example.com/one",
    title: "Doc one",
    content: "Octopuses have nine brains.",
    published_at: null,
    fetched_at: new Date().toISOString(),
    source_updated_at: null,
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
    source_updated_at: null,
    metadata: {},
    ...overrides,
  };
}

/**
 * Routes `fetch` calls by "METHOD /path" (with the query string:
 * "GET /cards?q=knicks"). Unknown routes fail the test, except card
 * requests: tests that do not care about the card get "no card".
 */
export function mockApi(routes: Record<string, (body: unknown) => unknown | Response>) {
  const calls: { key: string; body: unknown }[] = [];
  const spy = vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const path = String(input).replace(/^\/api/, "");
    const key = `${init?.method ?? "GET"} ${path}`;
    const body = init?.body ? JSON.parse(String(init.body)) : undefined;
    calls.push({ key, body });
    const handler = routes[key] ?? (path.startsWith("/cards?") ? () => noCard() : undefined);
    if (!handler) throw new Error(`Unexpected request: ${key}`);
    const value = handler(body);
    if (value instanceof Response) return value;
    return new Response(JSON.stringify({ data: value }), { status: 200 });
  });
  return { calls, spy };
}
