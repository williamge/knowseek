import { useState, type FormEvent } from "react";
import { everyInterval, timeAgo } from "../lib/format";
import type { TopicsApi } from "../lib/useTopics";

const INTERVALS = [
  { label: "Every hour", seconds: 3600 },
  { label: "Every 6 hours", seconds: 6 * 3600 },
  { label: "Every day", seconds: 24 * 3600 },
  { label: "Every week", seconds: 7 * 24 * 3600 },
];

interface Props {
  topics: TopicsApi;
  onSearch: (query: string) => void;
}

export function TopicsPage({ topics, onSearch }: Props) {
  const [unfollowError, setUnfollowError] = useState<string | null>(null);

  const unfollow = async (id: string) => {
    setUnfollowError(null);
    try {
      await topics.unfollow(id);
    } catch (e) {
      setUnfollowError(e instanceof Error ? e.message : String(e));
    }
  };

  return (
    <section className="topics">
      <h1>Topics you follow</h1>
      <p className="muted">
        Knowseek checks each topic on its schedule and adds new sources to the index.
      </p>

      <NewTopicForm topics={topics} />

      {topics.error && (
        <div className="notice notice--error" role="alert">
          Could not load topics: {topics.error}
        </div>
      )}
      {unfollowError && (
        <div className="notice notice--error" role="alert">
          Could not unfollow the topic: {unfollowError}
        </div>
      )}
      {topics.loaded && topics.topics.length === 0 && !topics.error && (
        <p className="muted">You do not follow any topics yet.</p>
      )}

      <ul className="topic-list">
        {topics.topics.map((topic) => (
          <li key={topic.id} className="topic">
            <button type="button" className="topic__query" onClick={() => onSearch(topic.query)}>
              {topic.query}
            </button>
            <span className="topic__meta">
              Checked {everyInterval(topic.refresh_interval_seconds)}
              {" · "}
              {topic.last_refreshed_at
                ? `last checked ${timeAgo(topic.last_refreshed_at)}`
                : "not checked yet"}
            </span>
            <button
              type="button"
              className="link-button"
              aria-label={`Unfollow ${topic.query}`}
              onClick={() => unfollow(topic.id)}
            >
              Unfollow
            </button>
          </li>
        ))}
      </ul>
    </section>
  );
}

function NewTopicForm({ topics }: { topics: TopicsApi }) {
  const [query, setQuery] = useState("");
  const [interval, setRefreshInterval] = useState(24 * 3600);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    if (!query.trim()) return;
    setBusy(true);
    setError(null);
    try {
      await topics.follow({ query: query.trim(), refresh_interval_seconds: interval });
      setQuery("");
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <form className="topic-form" onSubmit={submit}>
      <input
        aria-label="New topic"
        placeholder="Follow a new topic, for example “fusion energy startups”"
        value={query}
        onChange={(event) => setQuery(event.target.value)}
      />
      <select
        aria-label="Check interval"
        value={interval}
        onChange={(event) => setRefreshInterval(Number(event.target.value))}
      >
        {INTERVALS.map((option) => (
          <option key={option.seconds} value={option.seconds}>
            {option.label}
          </option>
        ))}
      </select>
      <button type="submit" className="pill pill--primary" disabled={busy || !query.trim()}>
        Follow
      </button>
      {error && (
        <span className="error-text" role="alert">
          {error}
        </span>
      )}
    </form>
  );
}
