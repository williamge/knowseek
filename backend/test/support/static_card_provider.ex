defmodule Knowseek.Cards.StaticProvider do
  @moduledoc "A `Knowseek.Cards.Provider` for tests: handles every entity, no HTTP, a fixed card."
  @behaviour Knowseek.Cards.Provider

  @impl true
  def handles?(_entity), do: true

  @impl true
  def fetch(entity) do
    {:ok, %{type: "sports_team", title: entity.label, facts: %{league: "Fake"}}, 60_000}
  end
end
