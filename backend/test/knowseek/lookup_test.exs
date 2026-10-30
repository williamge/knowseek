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

  test "does not enqueue discovery when coverage is sufficient" do
    for i <- 1..3, do: document_fixture(body: "Hydrothermal vents, part #{i}.")

    {:ok, result} = Lookup.run("hydrothermal vents")

    assert result.coverage == :sufficient
    assert result.discovery == :not_needed
    refute_enqueued(worker: SeekWorker)
  end
end
