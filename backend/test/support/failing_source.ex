defmodule Knowseek.Discovery.FailingSource do
  @moduledoc "A discovery source for tests. Always fails."
  @behaviour Knowseek.Discovery.Source

  @impl true
  def name, do: "failing"

  @impl true
  def discover(_query, _opts), do: {:error, :unavailable}
end
