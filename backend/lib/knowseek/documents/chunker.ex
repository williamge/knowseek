defmodule Knowseek.Documents.Chunker do
  @moduledoc """
  Splits a document body into chunks for indexing.

  Packs whole paragraphs into chunks of at most `:max_chars` characters.
  A paragraph that is longer than `:max_chars` is split on word boundaries.
  This is a deliberately simple first version.
  """

  @default_max_chars 1_200

  @spec chunk(String.t(), keyword()) :: [String.t()]
  def chunk(text, opts \\ []) when is_binary(text) do
    max_chars = Keyword.get(opts, :max_chars, @default_max_chars)

    text
    |> String.split(~r/\n\s*\n/, trim: true)
    |> Enum.map(&normalize_whitespace/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(&split_long(&1, max_chars))
    |> pack(max_chars)
  end

  defp normalize_whitespace(text), do: text |> String.split() |> Enum.join(" ")

  defp split_long(paragraph, max_chars) do
    if String.length(paragraph) <= max_chars do
      [paragraph]
    else
      paragraph |> String.split(" ") |> pack(max_chars, " ")
    end
  end

  # Greedily joins pieces with `joiner` while the result fits in `max_chars`.
  defp pack(pieces, max_chars, joiner \\ "\n\n") do
    pieces
    |> Enum.reduce([], fn
      piece, [] ->
        [piece]

      piece, [current | done] ->
        candidate = current <> joiner <> piece

        if String.length(candidate) <= max_chars,
          do: [candidate | done],
          else: [piece, current | done]
    end)
    |> Enum.reverse()
  end
end
