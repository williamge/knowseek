defmodule Knowseek.Crawl.Score do
  @moduledoc """
  The parts of a link's score (#89, ADR 0033). Pure.

      score = interest * novelty + gap + shared

  `interest` is how close the link's title and description are to the
  searches that showed its source page. `novelty` is how few stored pages are
  already near it. `gap` is a bonus for a source page that was a search's only
  result. `shared` is a bonus for a link that several of your source pages
  have, scaled by how rare that sharing is among the source page's links.
  """

  @doc "The cosine similarity of two vectors; `0.0` when either has no length."
  @spec cosine([number()], [number()]) :: float()
  def cosine(a, b) do
    {dot, norm_a, norm_b} =
      a
      |> Enum.zip(b)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {x, y}, {dot, na, nb} ->
        {dot + x * y, na + x * x, nb + y * y}
      end)

    if norm_a == 0.0 or norm_b == 0.0,
      do: 0.0,
      else: dot / (:math.sqrt(norm_a) * :math.sqrt(norm_b))
  end

  @doc "The largest cosine of `vector` to any of `query_vectors`; `0.0` for no queries."
  @spec interest([number()], [[number()]]) :: float()
  def interest(_vector, []), do: 0.0

  def interest(vector, query_vectors),
    do: query_vectors |> Enum.map(&cosine(vector, &1)) |> Enum.max()

  @doc "`1 - near / full`, with `near` capped at `full`: 1.0 when nothing is near, 0.0 when `full` pages are."
  @spec novelty(non_neg_integer(), pos_integer()) :: float()
  def novelty(near, full), do: 1.0 - min(near, full) / full

  @doc "`interest * novelty + gap`: the score before the shared bonus."
  @spec base(float(), float(), float()) :: float()
  def base(interest, novelty, gap), do: interest * novelty + gap

  @doc """
  How rare it is for a link to be shared by `count` source pages. `counts` are
  the link counts of every link of the source page. `0.0` when `count` is 1 or
  the page has fewer than two links; else `ln(n / n_ge) / ln(n)`, with `n` the
  number of links and `n_ge` the links whose count is at least `count`.
  """
  @spec rarity(pos_integer(), [pos_integer()]) :: float()
  def rarity(count, counts) when count <= 1 or length(counts) < 2, do: 0.0

  def rarity(count, counts) do
    n = length(counts)
    n_ge = Enum.count(counts, &(&1 >= count))
    :math.log(n / n_ge) / :math.log(n)
  end

  @doc "The shared bonus: `bonus * min(count - 1, 2) / 2 * rarity`."
  @spec shared(pos_integer(), float(), float()) :: float()
  def shared(count, rarity, bonus), do: bonus * min(count - 1, 2) / 2 * rarity

  @doc "The text that is embedded for a link: `\"Title: description\"`, or the title alone."
  @spec text(String.t(), String.t() | nil) :: String.t()
  def text(title, nil), do: title
  def text(title, ""), do: title
  def text(title, description), do: "#{title}: #{description}"
end
