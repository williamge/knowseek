defmodule Knowseek.Entities.FakeResolver do
  @moduledoc """
  A `Knowseek.Entities.Resolver` for tests: no HTTP. `"fake"` finds a
  basketball team, `"dup"` finds three (two share a label), `"boom"` fails,
  anything else finds nothing.
  """
  @behaviour Knowseek.Entities.Resolver

  alias Knowseek.Entities.Entity

  @impl true
  def search("fake", _opts) do
    {:ok,
     [
       %Entity{
         id: "Q-fake",
         label: "Fake Team",
         types: ["Q13393265"],
         sitelinks: 1,
         wikipedia_title: "Fake Team"
       }
     ]}
  end

  def search("dup", _opts) do
    team = fn id, label ->
      %Entity{id: id, label: label, types: ["Q13393265"], sitelinks: 1}
    end

    {:ok, [team.("Q-1", "Same Name"), team.("Q-2", "Same name "), team.("Q-3", "Other Name")]}
  end

  def search("boom", _opts), do: {:error, :boom}
  def search(_text, _opts), do: {:ok, []}
end
