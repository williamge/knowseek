defmodule Knowseek.Cards.BadProvider do
  @moduledoc "A `Knowseek.Cards.Provider` for tests that handles everything and returns a bad answer."
  @behaviour Knowseek.Cards.Provider

  @impl true
  def handles?(_entity), do: true

  @impl true
  def fetch(_entity), do: {:ok, %{type: "x"}, 1_000}
end
