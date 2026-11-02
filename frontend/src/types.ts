// Shapes of the JSON API in backend/lib/knowseek_web/controllers/*_json.ex.

export type Coverage = "sufficient" | "partial" | "none";

export type Discovery =
  | { status: "not_needed" }
  | { status: "enqueued"; job_id: number }
  | { status: "error"; reason: string };

/** Another matching chunk of a hit's document. */
export interface Passage {
  chunk_id: string;
  content: string;
  score: number;
}

/** One search hit: a document, shown by its best matching chunk. */
export interface Hit {
  document_id: string;
  chunk_id: string;
  url: string;
  title: string | null;
  content: string;
  published_at: string | null;
  fetched_at: string;
  /** When the source says the page was last edited. Null when it does not say. */
  source_updated_at: string | null;
  score: number;
  keyword_rank: number | null;
  semantic_rank: number | null;
  similarity: number | null;
  /** Other matching chunks of the document, best first. */
  passages: Passage[];
}

export interface SearchResult {
  query: string;
  coverage: Coverage;
  discovery: Discovery;
  hits: Hit[];
}

export interface KnowseekDocument {
  id: string;
  url: string;
  title: string | null;
  body: string;
  source: string;
  published_at: string | null;
  fetched_at: string;
  source_updated_at: string | null;
  metadata: Record<string, unknown>;
}

/** What `GET /api/documents` returns: a document without its body. */
export type DocumentSummary = Omit<KnowseekDocument, "body">;

/** What `GET /api/cards?q=` returns (`KnowseekWeb.CardJSON`). */
export type CardStatus = "pending" | "fresh" | "stale" | "unavailable" | "none";

/** The entity a query is about (`KnowseekWeb.CardJSON`). `kind` is `sports_team`, `company`, ... */
export interface CardEntity {
  id: string;
  label: string | null;
  description: string | null;
  kind: string | null;
  wikipedia_title: string | null;
}

/** `home_away` is "home" or "away". Dates are ISO 8601, UTC. */
export interface TeamLiveGame {
  opponent: string | null;
  home_away: string | null;
  team_score: number | null;
  opponent_score: number | null;
  period: number | null;
  clock: string | null;
  /** ESPN's short status, for example "End of 3rd" or "7:12 - 2nd". */
  status_text: string | null;
}

export interface TeamLastGame {
  date: string;
  opponent: string | null;
  home_away: string | null;
  /** "W" or "L"; null when ESPN does not say. */
  result: "W" | "L" | null;
  team_score: number | null;
  opponent_score: number | null;
}

export interface TeamNextGame {
  date: string;
  opponent: string | null;
  home_away: string | null;
}

export interface TeamInjury {
  player: string;
  status: string;
}

export interface SportsTeamFacts {
  source: string;
  league: string;
  record: string | null;
  live: TeamLiveGame | null;
  last_game: TeamLastGame | null;
  next_game: TeamNextGame | null;
  injuries: TeamInjury[];
}

/** Metric values (°C, km/h, mm); the UI converts them to the reader's units. A number is null when the source lacks it. */
export interface WeatherCurrent {
  temperature_c: number | null;
  apparent_temperature_c: number | null;
  humidity_percent: number | null;
  precipitation_mm: number | null;
  wind_speed_kmh: number | null;
  wind_direction_deg: number | null;
  is_day: boolean;
  /** WMO weather code. */
  weather_code: number | null;
  /** Short text for the code ("Light rain"), from the backend's table. */
  condition: string;
  /** An emoji for the code. */
  icon: string;
}

export interface WeatherDay {
  /** The place's local date, "2026-11-01". */
  date: string;
  high_c: number | null;
  low_c: number | null;
  precipitation_probability_percent: number | null;
  weather_code: number | null;
  condition: string;
  icon: string;
  /** The place's local time without offset, "2026-11-01T06:02". */
  sunrise: string | null;
  sunset: string | null;
}

export interface WeatherFacts {
  /** The credit Open-Meteo's license requires (CC BY 4.0), and its URL. */
  source: string;
  source_url: string;
  /** IANA time zone of the place, for example "Asia/Tokyo". */
  timezone: string;
  utc_offset_seconds: number;
  /** When the current conditions are from (ISO 8601, UTC). */
  observed_at: string;
  current: WeatherCurrent;
  /** Today first, then the next days. */
  daily: WeatherDay[];
}

/** A card of live facts. `type` says which shape `facts` has. */
export type FactCard =
  | { type: "sports_team"; title: string; facts: SportsTeamFacts }
  | { type: "weather"; title: string; facts: WeatherFacts };

export interface CardResponse {
  status: CardStatus;
  /** Null while the entity is not resolved, and for `none`. */
  entity: CardEntity | null;
  /** Other entities of the same kind that the query may mean. */
  alternatives: CardEntity[];
  /** Null unless the status is `fresh` or `stale`. */
  card: FactCard | null;
  /** When the card data was fetched (ISO 8601, UTC). */
  as_of: string | null;
  /** When to ask again, in milliseconds. */
  refresh_after_ms: number;
}
