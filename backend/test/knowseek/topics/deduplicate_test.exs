defmodule Knowseek.Topics.DeduplicateTest do
  # Drops the unique index and the NOT NULL constraint inside the test
  # transaction (Postgres DDL is transactional) to rebuild the state before
  # the migration. The table lock makes this unsafe next to async tests.
  use Knowseek.DataCase, async: false

  alias Knowseek.Topics.Deduplicate

  setup do
    Repo.query!("DROP INDEX topics_normalized_query_md5_index")
    Repo.query!("ALTER TABLE topics ALTER COLUMN normalized_query DROP NOT NULL")
    :ok
  end

  test "merges duplicates into the oldest row" do
    oldest =
      insert_legacy("Rust", ~U[2026-01-01 00:00:00Z],
        interval: 86_400,
        active: false,
        max_age_seconds: 7200,
        refreshed: ~U[2026-02-01 00:00:00Z]
      )

    middle =
      insert_legacy(" rust ", ~U[2026-01-02 00:00:00Z],
        interval: 3600,
        active: true,
        max_age_seconds: 600,
        refreshed: ~U[2026-03-01 00:00:00Z]
      )

    newest =
      insert_legacy("RUST", ~U[2026-01-03 00:00:00Z],
        interval: 604_800,
        active: false,
        max_age_seconds: 9000
      )

    other = insert_legacy("Elixir", ~U[2026-01-04 00:00:00Z], interval: 86_400, active: false)

    assert Deduplicate.run(Repo) == 2

    assert [kept, untouched] = topics()
    assert kept.id == oldest
    assert kept.query == "Rust"
    assert kept.normalized_query == "rust"
    assert kept.refresh_interval_seconds == 3600
    assert kept.active
    assert kept.max_age_seconds == 600
    assert kept.last_refreshed_at == ~U[2026-03-01 00:00:00Z]

    assert untouched.id == other
    assert untouched.normalized_query == "elixir"
    refute untouched.active
    assert untouched.refresh_interval_seconds == 86_400

    refute middle in Enum.map([kept, untouched], & &1.id)
    refute newest in Enum.map([kept, untouched], & &1.id)

    # The state the migration leaves behind accepts the unique index.
    Repo.query!("ALTER TABLE topics ALTER COLUMN normalized_query SET NOT NULL")

    Repo.query!(
      "CREATE UNIQUE INDEX topics_normalized_query_md5_index ON topics (md5(normalized_query))"
    )
  end

  test "merges queries far above the size of a btree index entry" do
    long = String.duplicate("研", 1000)
    assert byte_size(long) > 2704

    oldest = insert_legacy(long, ~U[2026-01-01 00:00:00Z], interval: 86_400)
    insert_legacy(" " <> long <> " ", ~U[2026-01-02 00:00:00Z], interval: 3600)

    assert Deduplicate.run(Repo) == 1
    assert [%{id: ^oldest, refresh_interval_seconds: 3600}] = topics()

    Repo.query!("ALTER TABLE topics ALTER COLUMN normalized_query SET NOT NULL")

    Repo.query!(
      "CREATE UNIQUE INDEX topics_normalized_query_md5_index ON topics (md5(normalized_query))"
    )
  end

  test "keeps a null max_age_seconds, because null means every refresh seeks new data" do
    oldest = insert_legacy("rust", ~U[2026-01-01 00:00:00Z], max_age_seconds: 600)
    insert_legacy("Rust", ~U[2026-01-02 00:00:00Z], max_age_seconds: nil)
    insert_legacy("RUST", ~U[2026-01-03 00:00:00Z], max_age_seconds: 60)

    assert Deduplicate.run(Repo) == 2

    assert [%{id: ^oldest, max_age_seconds: nil}] = topics()
  end

  test "keeps a null last_refreshed_at when no duplicate was refreshed" do
    insert_legacy("rust", ~U[2026-01-01 00:00:00Z])
    insert_legacy("Rust", ~U[2026-01-02 00:00:00Z])

    Deduplicate.run(Repo)

    assert [%{last_refreshed_at: nil}] = topics()
  end

  test "backfills topics without duplicates and is a no-op when run again" do
    insert_legacy("  Fusion   Energy ", ~U[2026-01-01 00:00:00Z])

    assert Deduplicate.run(Repo) == 0
    assert Deduplicate.run(Repo) == 0

    assert [%{query: "  Fusion   Energy ", normalized_query: "fusion energy"}] = topics()
  end

  # Inserts a row the way the schema did before the column existed.
  defp insert_legacy(query, inserted_at, opts \\ []) do
    id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO topics
        (id, query, active, refresh_interval_seconds, max_age_seconds,
         last_refreshed_at, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $7)
      """,
      [
        Ecto.UUID.dump!(id),
        query,
        Keyword.get(opts, :active, true),
        Keyword.get(opts, :interval, 86_400),
        Keyword.get(opts, :max_age_seconds),
        Keyword.get(opts, :refreshed),
        inserted_at
      ]
    )

    id
  end

  defp topics, do: Repo.all(from t in Knowseek.Topics.Topic, order_by: [asc: t.inserted_at])
end
