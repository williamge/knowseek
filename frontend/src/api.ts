import type { CardResponse, DocumentSummary, KnowseekDocument, SearchResult } from "./types";

export class ApiError extends Error {
  readonly status: number;

  constructor(status: number, message: string) {
    super(message);
    this.name = "ApiError";
    this.status = status;
  }
}

async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
  const response = await fetch(`/api${path}`, {
    ...init,
    headers: { accept: "application/json", "content-type": "application/json", ...init.headers },
  });

  const body: unknown = await response.json().catch(() => null);
  if (!response.ok) throw new ApiError(response.status, errorMessage(body) ?? response.statusText);
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
