defmodule Knowseek.LookupTest do
  use Knowseek.DataCase, async: true

  alias Knowseek.Discovery.SeekWorker
  alias Knowseek.Lookup

  test "enqueues discovery when coverage is not sufficient" do
    {:ok, result} = Lookup.run("deep sea vents")

    assert result.coverage == :none
    assert {:enqueued, _job_id} = result.discovery
    assert_enqueued(worker: SeekWorker, args: %{"query" => "deep sea vents"})
  end

  test "returns no hits and enqueues discovery when the index holds only unrelated documents" do
    document_fixture(body: "Sourdough bread needs a long, slow fermentation.")

    {:ok, result} = Lookup.run("heavy metal")

    assert result.hits == []
    assert result.coverage == :none
    assert {:enqueued, _job_id} = result.discovery
  end

  test "does not enqueue discovery when coverage is sufficient" do
    for i <- 1..3, do: document_fixture(body: "Hydrothermal vents, part #{i}.")

    {:ok, result} = Lookup.run("hydrothermal vents")

    assert result.coverage == :sufficient
    assert result.discovery == :not_needed
    refute_enqueued(worker: SeekWorker)
  end

  test "enqueues discovery when the matching documents are too old" do
    old = ~U[2020-01-01 00:00:00Z]
    for i <- 1..3, do: document_fixture(body: "Tidal energy, part #{i}.", fetched_at: old)

    {:ok, result} = Lookup.run("tidal energy", max_age_seconds: 86_400)

    assert result.coverage == :none
    assert {:enqueued, _job_id} = result.discovery
    assert_enqueued(worker: SeekWorker, args: %{"query" => "tidal energy"})
  end
end
