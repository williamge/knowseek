defmodule KnowseekWeb.CrawlJSON do
  @moduledoc "JSON for `Knowseek.Crawl.overview/1`. Scores are rounded to 3 decimals."

  @rounded [:interest, :novelty, :gap, :shared, :score]

  def show(%{overview: overview}) do
    %{
      data: %{
        mode: overview.mode,
        pages_per_day: overview.pages_per_day,
        fetched_today: overview.fetched_today,
        bar: overview.bar,
        next: Enum.map(overview.next, &entry/1)
      }
    }
  end

  defp entry(entry), do: Enum.reduce(@rounded, entry, &Map.update!(&2, &1, fn n -> round3(n) end))

  defp round3(number), do: Float.round(number * 1.0, 3)
end
