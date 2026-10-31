import { useCallback, useEffect, useState } from "react";
import { api } from "../api";
import type { NewTopic, Topic } from "../types";
import { normalizeQuery } from "./format";

export interface TopicsApi {
  topics: Topic[];
  loaded: boolean;
  error: string | null;
  follow: (topic: NewTopic) => Promise<Topic>;
  unfollow: (id: string) => Promise<void>;
  /** The topic that follows `query`, if any. Compares normalized queries. */
  findByQuery: (query: string) => Topic | undefined;
}

export function useTopics(): TopicsApi {
  const [topics, setTopics] = useState<Topic[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    api
      .listTopics()
      .then(setTopics, (e: Error) => setError(e.message))
      .finally(() => setLoaded(true));
  }, []);

  const follow = useCallback(async (input: NewTopic) => {
    // The API returns the existing topic when the query is already followed.
    const topic = await api.createTopic(input);
    setTopics((current) =>
      current.some((existing) => existing.id === topic.id) ? current : [...current, topic],
    );
    return topic;
  }, []);

  const unfollow = useCallback(async (id: string) => {
    await api.deleteTopic(id);
    setTopics((current) => current.filter((topic) => topic.id !== id));
  }, []);

  const findByQuery = useCallback(
    (query: string) => {
      const normalized = normalizeQuery(query);
      return topics.find((topic) => normalizeQuery(topic.query) === normalized);
    },
    [topics],
  );

  return { topics, loaded, error, follow, unfollow, findByQuery };
}
