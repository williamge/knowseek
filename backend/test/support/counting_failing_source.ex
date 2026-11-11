defmodule Knowseek.Discovery.CountingFailingSource do
  @moduledoc "A discovery source for tests. Reports 500 downloaded bytes, then fails."
  @behaviour Knowseek.Discovery.Source

  @impl true
  def name, do: "counting_failing"

  @impl true
  def discover(_query, opts) do
    opts[:on_bytes].(500)
    {:error, :boom}
  end
end
