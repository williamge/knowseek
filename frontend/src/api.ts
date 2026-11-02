import type { CardResponse, DocumentSummary, KnowseekDocument, SearchResult } from "./types";

export class ApiError extends Error {
  readonly status: number;
  /** The `Retry-After` header of the response in milliseconds, when it has one in seconds. */
  readonly retryAfterMs: number | null;

  constructor(status: number, message: string, retryAfterMs: number | null = null) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.retryAfterMs = retryAfterMs;
  }
}

/** Wait at least this long after a 429, whatever `Retry-After` says: no hot loop. */
export const MIN_RETRY_MS = 1000;
/** Wait at most this long after a 429; a longer `Retry-After` is not believed. */
export const MAX_RETRY_MS = 60_000;
/** The wait after a 429 without a usable `Retry-After`. */
export const DEFAULT_RETRY_MS = 5000;

/**
 * How long to wait before asking again after `error`, or `null` when `error`
 * is not a 429 (HTTP "too many requests"). The server's `Retry-After`, kept
 * within `MIN_RETRY_MS`..`MAX_RETRY_MS`.
 */
export function rateLimitDelayMs(error: unknown): number | null {
  if (!(error instanceof ApiError) || error.status !== 429) return null;
  const ms = error.retryAfterMs ?? DEFAULT_RETRY_MS;
  return Math.min(Math.max(ms, MIN_RETRY_MS), MAX_RETRY_MS);
}

// `Retry-After` is seconds or an HTTP date; the API sends seconds.
function retryAfterMs(response: Response): number | null {
  const value = response.headers.get("retry-after")?.trim();
  return value && /^\d+$/.test(value) ? Number(value) * 1000 : null;
}

async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
  const response = await fetch(`/api${path}`, {
    ...init,
    headers: { accept: "application/json", "content-type": "application/json", ...init.headers },
  });

  const body: unknown = await response.json().catch(() => null);
  if (!response.ok) {
    throw new ApiError(
      response.status,
      errorMessage(body) ?? response.statusText,
      retryAfterMs(response),
    );
  }
  if (typeof body !== "object" || body === null || !("data" in body)) {
    throw new ApiError(response.status, "The API returned an unexpected response.");
  }
  return (body as { data: T }).data;
}

// The API returns `{errors: {detail: "..."}}` or changeset errors
// `{errors: {field: ["message"]}}`.
export function errorMessage(body: unknown): string | null {
  if (typeof body !== "object" || body === null || !("errors" in body)) return null;
  const errors = (body as { errors: Record<string, unknown> }).errors;
  if (typeof errors.detail === "string") return errors.detail;

  const parts = Object.entries(errors).map(([field, messages]) =>
    Array.isArray(messages) ? `${field} ${messages.join(", ")}` : field,
  );
  return parts.length > 0 ? parts.join("; ") : null;
}

export const api = {
  search: (query: string, opts: { limit?: number; signal?: AbortSignal } = {}) =>
    request<SearchResult>("/search", {
      method: "POST",
      body: JSON.stringify({ query, limit: opts.limit }),
      signal: opts.signal,
    }),

  listDocuments: (signal?: AbortSignal) => request<DocumentSummary[]>("/documents", { signal }),

  getDocument: (id: string, signal?: AbortSignal) =>
    request<KnowseekDocument>(`/documents/${encodeURIComponent(id)}`, { signal }),

  /** Cache-only on the server: it never waits for an upstream. Poll it. */
  getCard: (query: string, signal?: AbortSignal) =>
    request<CardResponse>(`/cards?q=${encodeURIComponent(query)}`, { signal }),
};
