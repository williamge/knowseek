defmodule Knowseek.Entities.Intent do
  @moduledoc """
  Splits an intent word off a query before it is resolved. Plain code, not an
  LLM; task 007 (query planning) may replace it.

  `weather in tokyo` finds nothing in Wikidata, so the query is split into the
  intent `:weather` and the text `tokyo`. Two shapes are recognised, ignoring
  case and extra spaces:

    * `weather in <place>`
    * `<place> weather`

  Anything else, including a bare `weather`, has no intent and is returned
  whole.

  Limits: the text before or after `weather` is not checked. `knicks weather`
  is `{:weather, "knicks"}` although a team has no weather, so a consumer
  checks the kind of the entity (`Knowseek.Entities.kind/1`), and `weather in
  tokyo and osaka` is the text `tokyo and osaka`.
  """

  @type intent :: :weather | nil

  @doc """
  Returns `{intent, text}`. `text` is trimmed and has single spaces between
  words; its case is kept.

      iex> Knowseek.Entities.Intent.split("Weather in  Tokyo")
      {:weather, "Tokyo"}

      iex> Knowseek.Entities.Intent.split("tokyo weather")
      {:weather, "tokyo"}

      iex> Knowseek.Entities.Intent.split("knicks")
      {nil, "knicks"}
  """
  @spec split(String.t()) :: {intent(), String.t()}
  def split(query) when is_binary(query) do
    query = query |> String.split() |> Enum.join(" ")

    cond do
      captures = Regex.named_captures(~r/\Aweather in (?<text>.+)\z/iu, query) ->
        {:weather, captures["text"]}

      captures = Regex.named_captures(~r/\A(?<text>.+?) weather\z/iu, query) ->
        {:weather, captures["text"]}

      true ->
        {nil, query}
    end
  end
end
