defmodule Knowseek.Discovery.BadCandidateSource do
  @moduledoc "A discovery source for tests. Returns a candidate that fails to ingest (no body)."
  @behaviour Knowseek.Discovery.Source

  @impl true
  def name, do: "bad_candidate"

  @impl true
  def discover(query, _opts),
    do: {:ok, [%{url: "https://bad.example/#{query}", title: "No body"}]}
end
