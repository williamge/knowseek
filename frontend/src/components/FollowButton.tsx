import { useState } from "react";
import type { TopicsApi } from "../lib/useTopics";

export function FollowButton({ query, topics }: { query: string; topics: TopicsApi }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const topic = topics.findByQuery(query);

  const toggle = async () => {
    setBusy(true);
    setError(null);
    try {
      if (topic) await topics.unfollow(topic.id);
      else await topics.follow({ query });
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  if (!topics.loaded) return null;

  return (
    <div className="follow">
      <button
        type="button"
        className={`pill${topic ? " pill--active" : ""}`}
        aria-pressed={Boolean(topic)}
        disabled={busy}
        onClick={toggle}
        title={
          topic ? "Stop following this topic" : "Knowseek checks this topic for new data every day"
        }
      >
        {topic ? "✓ Following" : "+ Follow topic"}
      </button>
      {error && (
        <span className="error-text" role="alert">
          {error}
        </span>
      )}
    </div>
  );
}
