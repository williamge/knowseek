import type {
  Crawl,
  CrawlEntry,
  BlockedLinks,
  CardEntity,
  CardResponse,
  Hit,
  KnowseekDocument,
  SearchResult,
  SportsTeamFacts,
  Stats,
  WeatherFacts,
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
    source: "balldontlie",
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
    ...overrides,
  };
}

export const tokyoEntity: CardEntity = {
  id: "Q1490",
  label: "Tokyo",
  description: "capital and largest city of Japan",
  kind: "place",
  wikipedia_title: "Tokyo",
};

/** Tokyo on 2026-11-01 as the backend sends it (metric), from the recorded Open-Meteo answer. */
export function weatherFacts(overrides: Partial<WeatherFacts> = {}): WeatherFacts {
  const day = (
    date: string,
    high: number,
    low: number,
    chance: number,
    code: number,
    icon: string,
    condition: string,
  ) => ({
    date,
    high_c: high,
    low_c: low,
    precipitation_probability_percent: chance,
    weather_code: code,
    condition,
    icon,
    sunrise: `${date}T06:02`,
    sunset: `${date}T16:46`,
  });

  return {
    source: "Open-Meteo.com",
    source_url: "https://open-meteo.com/",
    timezone: "Asia/Tokyo",
    utc_offset_seconds: 32_400,
    observed_at: "2026-11-01T01:00:00Z",
    current: {
      temperature_c: 17,
      apparent_temperature_c: 15.7,
      humidity_percent: 55,
      precipitation_mm: 0,
      wind_speed_kmh: 4.7,
      wind_direction_deg: 351,
      is_day: true,
      weather_code: 0,
      condition: "Clear sky",
      icon: "☀️",
    },
    daily: [
      day("2026-11-01", 19.9, 11.7, 0, 3, "☁️", "Overcast"),
      day("2026-11-02", 22, 12.6, 84, 53, "🌦️", "Drizzle"),
      day("2026-11-03", 19.4, 11.7, 5, 51, "🌦️", "Light drizzle"),
      day("2026-11-04", 15.4, 12.2, 42, 51, "🌦️", "Light drizzle"),
      day("2026-11-05", 17.3, 11.5, 80, 81, "🌧️", "Rain showers"),
    ],
    ...overrides,
  };
}

/** A fresh weather card for Tokyo. */
export function weatherResponse(overrides: Partial<CardResponse> = {}): CardResponse {
  return cardResponse({
    entity: tokyoEntity,
    alternatives: [],
    card: { type: "weather", title: "Tokyo", facts: weatherFacts() },
    as_of: "2026-11-01T01:00:20Z",
    refresh_after_ms: 60_000,
    ...overrides,
  });
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
    license: "LicenseRef-unknown",
    attribution: null,
    modified: false,
    share: "none",
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
    reembedding: null,
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
    license: "LicenseRef-unknown",
    attribution: null,
    modified: false,
    share: "none",
    origin: "search",
    origin_query: null,
    metadata: {},
    ...overrides,
  };
}

/** A response of `GET /api/stats`. The default has some searches, pages and downloads. */
export function stats(overrides: Partial<Stats> = {}): Stats {
  return {
    searches: {
      total: 42,
      days: [
        { day: "2026-11-10", sufficient: 3, partial: 1, none: 2 },
        { day: "2026-11-09", sufficient: 0, partial: 0, none: 4 },
      ],
    },
    pages: { search: 110, background: 0, manual: 10 },
    budget: {
      disk: { used: 124_000_000, limit: 5_000_000_000, state: "ok" },
      network: { used: 812_345, limit: 200_000_000, state: "ok" },
      free_disk: { bytes: 11_600_000_000, floor: 1_000_000_000, low: false },
      background_share: 0.9,
    },
    passages: 16_200,
    network: [
      { day: "2026-11-10", source: "wikipedia", bytes: 512_000 },
      { day: "2026-11-10", source: "wikibooks", bytes: 900 },
    ],
    hit_share: { background_pages: 0, hit_pages: 0 },
    gain: { pages: 0, searches: 0, window_searches: 0 },
    crawl: {
      mode: "preview",
      pages_per_day: 100,
      fetched_today: 0,
      fetched: 0,
      links_read: 1234,
      candidates: 87,
      stored_bytes: 0,
    },
    index: {
      model: {
        name: "ollama/bge-m3:latest",
        digest: "7907646426070047a77226ac3e684fbbe8410524f7b4a74d02837e43f2146bab",
        dimensions: 1024,
        quantization: "float32",
      },
      passages: 300,
      current_passages: 300,
      eta_seconds: null,
    },
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

/** What `GET /api/blocked-links` returns (`KnowseekWeb.BlockedLinkJSON`). */
export function blockedLinks(overrides: Partial<BlockedLinks> = {}): BlockedLinks {
  return {
    allowed_hosts: ["en.wikipedia.org", "en.wikibooks.org"],
    total_domains: 2,
    total_links: 5,
    domains: [
      {
        host: "web.archive.org",
        links: 3,
        pages: 2,
        times_seen: 4,
        first_seen_at: "2020-11-10T22:23:02Z",
        example_url:
          "https://web.archive.org/web/2019/http://www.sheldonbrown.com/tires.html?a-very-long-query=1",
      },
      {
        host: "sheldonbrown.com",
        links: 2,
        pages: 1,
        times_seen: 1,
        first_seen_at: "2020-11-10T22:23:02Z",
        example_url: "http://www.sheldonbrown.com/tires.html",
      },
    ],
    ...overrides,
  };
}

/** One scored link of `GET /api/crawl`. */
export function crawlEntry(overrides: Partial<CrawlEntry> = {}): CrawlEntry {
  return {
    title: "Bicycle tires",
    description: "How to pick tires for a road bike.",
    url: "https://example.org/tires",
    source: {
      document_id: "doc-1",
      title: "Bicycle",
      url: "https://en.wikipedia.org/wiki/Bicycle",
      queries: ["road bike"],
    },
    interest: 0.8,
    novelty: 0.5,
    gap: 0,
    shared: 0,
    shared_count: 1,
    score: 0.65,
    document_id: null,
    fetched_at: null,
    stored_bytes: null,
    hit: false,
    ...overrides,
  };
}

/** A response of `GET /api/crawl`. */
export function crawl(overrides: Partial<Crawl> = {}): Crawl {
  return {
    mode: "preview",
    pages_per_day: 100,
    fetched_today: 0,
    paused: null,
    bar: 0.4,
    next: [crawlEntry()],
    fetched: [],
    ...overrides,
  };
}
