defmodule Knowseek.Topics.Deduplicate do
  @moduledoc """
  Data step of the migration that makes topics unique by normalized query.

  `run/1` fills `topics.normalized_query` for every row that has none, with
  `Knowseek.Discovery.normalize/1` (the same function `Topic.changeset/2`
  uses, so stored and future values agree). Then it merges topics that share
  a normalized query into one row.

  Merge rule, per group of duplicates:

    * The OLDEST row is kept (`inserted_at`, then `id`). Its id and `query`
      text stay as they are. The other rows are deleted.
    * `refresh_interval_seconds`: the shortest of the group.
    * `active`: `true` if any row of the group was active.
    * `max_age_seconds`: `NULL` if any row has `NULL`, because `NULL` means
      "every refresh seeks new data" and that need wins. Otherwise the
      smallest value, which is the strictest freshness need.
    * `last_refreshed_at`: the latest of the group, so the merged topic is
      not refreshed again right away.

  It uses plain SQL on the table, not the `Topic` schema, so later changes to
  the schema cannot change what an old migration does.
  """

  @merge_sql """
  WITH ranked AS (
    SELECT id,
           normalized_query,
           row_number() OVER (
             PARTITION BY normalized_query ORDER BY inserted_at, id
           ) AS position
    FROM topics
  ),
  merged AS (
    SELECT normalized_query,
           min(refresh_interval_seconds) AS refresh_interval_seconds,
           bool_or(active) AS active,
           CASE WHEN bool_or(max_age_seconds IS NULL) THEN NULL
                ELSE min(max_age_seconds) END AS max_age_seconds,
           max(last_refreshed_at) AS last_refreshed_at
    FROM topics
    GROUP BY normalized_query
    HAVING count(*) > 1
  ),
  updated AS (
    UPDATE topics t
    SET refresh_interval_seconds = m.refresh_interval_seconds,
        active = m.active,
        max_age_seconds = m.max_age_seconds,
        last_refreshed_at = m.last_refreshed_at,
        updated_at = now() AT TIME ZONE 'utc'
    FROM merged m, ranked r
    WHERE r.id = t.id AND r.position = 1 AND m.normalized_query = t.normalized_query
    RETURNING t.id
  )
  DELETE FROM topics t
  USING ranked r
  WHERE r.id = t.id AND r.position > 1
  """

  @doc "Backfills `normalized_query` and merges duplicate topics. Returns the number of rows deleted."
  @spec run(module()) :: non_neg_integer()
  def run(repo) do
    backfill(repo)
    %{num_rows: deleted} = repo.query!(@merge_sql)
    deleted
  end

  defp backfill(repo) do
    %{rows: rows} = repo.query!("SELECT id, query FROM topics WHERE normalized_query IS NULL")

    for [id, query] <- rows do
      repo.query!("UPDATE topics SET normalized_query = $1 WHERE id = $2", [
        Knowseek.Discovery.normalize(query),
        id
      ])
    end

    :ok
  end
end
