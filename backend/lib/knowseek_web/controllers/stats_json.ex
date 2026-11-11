defmodule KnowseekWeb.StatsJSON do
  @moduledoc "JSON for `Knowseek.Activity.stats/1` and `Knowseek.Crawl.stats/1`. Dates are ISO strings."

  def show(%{stats: stats, crawl: crawl}) do
    %{
      data: %{
        searches: %{
          total: stats.searches.total,
          days:
            Enum.map(
              stats.searches.days,
              &Map.update!(&1, :day, fn day -> Date.to_iso8601(day) end)
            )
        },
        pages: stats.pages,
        disk_bytes: stats.disk_bytes,
        network:
          Enum.map(stats.network, &Map.update!(&1, :day, fn day -> Date.to_iso8601(day) end)),
        hit_share: stats.hit_share,
        crawl: crawl
      }
    }
  end

  def cleared(%{deleted: deleted}), do: %{data: %{deleted: deleted}}
end
