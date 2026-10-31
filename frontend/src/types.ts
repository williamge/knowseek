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
  metadata: Record<string, unknown>;
}

/** What `GET /api/documents` returns: a document without its body. */
export type DocumentSummary = Omit<KnowseekDocument, "body">;

export interface Topic {
  id: string;
  query: string;
  active: boolean;
  refresh_interval_seconds: number;
  max_age_seconds: number | null;
  last_refreshed_at: string | null;
  inserted_at: string;
}

export interface NewTopic {
  query: string;
  refresh_interval_seconds?: number;
  max_age_seconds?: number | null;
}
