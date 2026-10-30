import type { KnowseekDocument, NewTopic, SearchResult, Topic } from "./types";

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

  if (response.status === 204) return undefined as T;

  const body: unknown = await response.json().catch(() => null);
  if (!response.ok) throw new ApiError(response.status, errorMessage(body) ?? response.statusText);
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

  listDocuments: (signal?: AbortSignal) => request<KnowseekDocument[]>("/documents", { signal }),

  getDocument: (id: string, signal?: AbortSignal) =>
    request<KnowseekDocument>(`/documents/${encodeURIComponent(id)}`, { signal }),

  listTopics: () => request<Topic[]>("/topics"),

  createTopic: (topic: NewTopic) =>
    request<Topic>("/topics", { method: "POST", body: JSON.stringify({ topic }) }),

  deleteTopic: (id: string) =>
    request<void>(`/topics/${encodeURIComponent(id)}`, { method: "DELETE" }),
};
