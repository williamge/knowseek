defmodule KnowseekWeb.CardJSON do
  alias Knowseek.Entities
  alias Knowseek.Entities.Entity

  def show(%{card: card}) do
    %{
      data: %{
        status: card.status,
        entity: entity(card.entity),
        alternatives: Enum.map(card.alternatives, &entity/1),
        card: card.card,
        as_of: card.as_of,
        refresh_after_ms: card.refresh_after_ms
      }
    }
  end

  defp entity(nil), do: nil

  defp entity(%Entity{} = entity) do
    %{
      id: entity.id,
      label: entity.label,
      description: entity.description,
      kind: Entities.kind(entity),
      wikipedia_title: entity.wikipedia_title
    }
  end
end
