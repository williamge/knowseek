import type { Hit } from "../types";

/** Same rule as `Knowseek.Discovery.normalize/1`: lowercase, collapse whitespace. */
export function normalizeQuery(query: string): string {
  return query.toLowerCase().split(/\s+/).filter(Boolean).join(" ");
}

const UNITS: [Intl.RelativeTimeFormatUnit, number][] = [
  ["year", 365 * 24 * 3600],
  ["month", 30 * 24 * 3600],
  ["week", 7 * 24 * 3600],
  ["day", 24 * 3600],
  ["hour", 3600],
  ["minute", 60],
];

const relative = new Intl.RelativeTimeFormat("en", { numeric: "auto" });

export function timeAgo(iso: string, now: Date = new Date()): string {
  const seconds = Math.round((new Date(iso).getTime() - now.getTime()) / 1000);
  for (const [unit, size] of UNITS) {
    if (Math.abs(seconds) >= size) return relative.format(Math.round(seconds / size), unit);
  }
  return "just now";
}

/** "Oct 29", or "Oct 29, 2025" when it is not this year. */
export function shortDate(iso: string, now: Date = new Date()): string {
  const date = new Date(iso);
  return date.toLocaleDateString("en", {
    month: "short",
    day: "numeric",
    ...(date.getFullYear() === now.getFullYear() ? {} : { year: "numeric" }),
  });
}

const INTERVALS: [string, number][] = [
  ["week", 7 * 24 * 3600],
  ["day", 24 * 3600],
  ["hour", 3600],
  ["minute", 60],
];

/** 86400 -> "every day", 21600 -> "every 6 hours". */
export function everyInterval(seconds: number): string {
  for (const [unit, size] of INTERVALS) {
    if (seconds >= size && seconds % size === 0) {
      const n = seconds / size;
      return n === 1 ? `every ${unit}` : `every ${n} ${unit}s`;
    }
  }
  return `every ${seconds} seconds`;
}

/** Documents without a URL get a `urn:knowseek:...` id. Those are not links. */
export function isWebUrl(url: string): boolean {
  return /^https?:\/\//i.test(url);
}

export function displayHost(url: string): string {
  if (!isWebUrl(url)) return "added manually";
  try {
    return new URL(url).hostname.replace(/^www\./, "");
  } catch {
    return url;
  }
}

/** A passage to show on a result card: the hit's best chunk, then its other passages. */
export interface CardPassage {
  chunk_id: string;
  content: string;
  score: number;
  /** Only the best chunk has ranks and a similarity. */
  keyword_rank: number | null;
  semantic_rank: number | null;
  similarity: number | null;
}

export interface HitGroup {
  documentId: string;
  title: string;
  url: string;
  fetchedAt: string;
  sourceUpdatedAt: string | null;
  publishedAt: string | null;
  passages: CardPassage[];
}

/** The API returns one hit per document. Shape each one for a result card. */
export function groupHits(hits: Hit[]): HitGroup[] {
  return hits.map((hit) => ({
    documentId: hit.document_id,
    title: hit.title?.trim() || displayHost(hit.url),
    url: hit.url,
    fetchedAt: hit.fetched_at,
    sourceUpdatedAt: hit.source_updated_at,
    publishedAt: hit.published_at,
    passages: [
      hit,
      ...hit.passages.map((passage) => ({
        ...passage,
        keyword_rank: null,
        semantic_rank: null,
        similarity: null,
      })),
    ],
  }));
}

export interface Segment {
  text: string;
  match: boolean;
}

const STOP_WORDS = new Set([
  "the",
  "and",
  "for",
  "are",
  "was",
  "what",
  "who",
  "how",
  "why",
  "with",
]);

export function queryTerms(query: string): string[] {
  const words = normalizeQuery(query)
    .split(" ")
    .map((word) => word.replace(/[^\p{L}\p{N}-]/gu, ""))
    .filter((word) => word.length >= 3 && !STOP_WORDS.has(word));
  return [...new Set(words)];
}

/** Splits `text` into segments, marking case-insensitive matches of the query terms. */
export function highlight(text: string, query: string): Segment[] {
  const terms = queryTerms(query);
  if (terms.length === 0) return [{ text, match: false }];

  const escaped = terms
    .sort((a, b) => b.length - a.length)
    .map((term) => term.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"));
  const pattern = new RegExp(`(${escaped.join("|")})`, "iu");

  // With a capture group, `split` puts the matches at the odd indexes.
  return text
    .split(pattern)
    .map((part, index) => ({ text: part, match: index % 2 === 1 }))
    .filter((segment) => segment.text !== "");
}

/** "3:42 PM", or "3:42:15 PM" with `seconds`, in the user's time zone. */
export function clockTime(iso: string, seconds = false): string {
  return new Date(iso).toLocaleTimeString("en", {
    hour: "numeric",
    minute: "2-digit",
    ...(seconds ? { second: "2-digit" } : {}),
  });
}

/** "Mon, Nov 2, 7:30 PM", in the user's time zone. */
export function gameTime(iso: string): string {
  return new Date(iso).toLocaleString("en", {
    weekday: "short",
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
}

/** "at Boston Celtics" or "vs Boston Celtics". */
export function versus(homeAway: string | null, opponent: string | null): string {
  if (!opponent) return "";
  return `${homeAway === "away" ? "at" : "vs"} ${opponent}`;
}
