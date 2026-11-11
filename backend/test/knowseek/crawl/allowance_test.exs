defmodule Knowseek.Crawl.AllowanceTest do
  use ExUnit.Case, async: true

  alias Knowseek.Crawl.Allowance

  @config [top_ranks: 3, earn_top: 5, earn_single: 15, earn_rest: 1, max_queries: 3]
  @t0 ~U[2026-11-01 12:00:00Z]

  defp appearance(attrs) do
    Map.merge(%{query: "q", rank: 1, single: false, at: @t0}, Map.new(attrs))
  end

  defp later(seconds), do: DateTime.add(@t0, seconds, :second)

  describe "earned/2" do
    test "is 5 at ranks 1 to 3" do
      for rank <- 1..3, do: assert(Allowance.earned([appearance(rank: rank)], @config) == 5)
    end

    test "is 1 at ranks 4 to 10" do
      for rank <- 4..10, do: assert(Allowance.earned([appearance(rank: rank)], @config) == 1)
    end

    test "is 15 as the single result, not 20" do
      assert Allowance.earned([appearance(rank: 1, single: true)], @config) == 15
    end

    test "sums the appearances" do
      appearances = [
        appearance(rank: 2),
        appearance(rank: 7),
        appearance(rank: 1, single: true)
      ]

      assert Allowance.earned(appearances, @config) == 21
    end
  end

  describe "sources/2" do
    test "puts pages that were a single result first, then the most shown" do
      pages = %{
        "a" => [appearance(rank: 1), appearance(rank: 2)],
        "b" => [appearance(rank: 1)],
        "c" => [appearance(single: true)]
      }

      assert pages |> Allowance.sources(@config) |> Enum.map(& &1.document_id) == ~w(c a b)
    end

    test "then the newest, then the id" do
      pages = %{
        "d" => [appearance(at: later(0))],
        "c" => [appearance(at: later(60))],
        "b" => [appearance(at: later(0))]
      }

      assert pages |> Allowance.sources(@config) |> Enum.map(& &1.document_id) == ~w(c b d)
    end

    test "fills in earned, gap, shown and last_at" do
      pages = %{
        "a" => [appearance(rank: 5, at: later(10)), appearance(single: true, at: later(0))]
      }

      assert [source] = Allowance.sources(pages, @config)
      assert source.earned == 16
      assert source.gap
      assert source.shown == 2
      assert source.last_at == later(10)
    end

    test "has no gap without a single-result search" do
      assert [%{gap: false}] = Allowance.sources(%{"a" => [appearance(rank: 1)]}, @config)
    end

    test "lists the distinct queries newest first, cut at max_queries" do
      pages = %{
        "a" => [
          appearance(query: "old", at: later(0)),
          appearance(query: "newest", at: later(40)),
          appearance(query: "dup", at: later(10)),
          appearance(query: "dup", at: later(20)),
          appearance(query: "mid", at: later(30))
        ]
      }

      assert [%{queries: ["newest", "mid", "dup"]}] = Allowance.sources(pages, @config)
    end
  end
end
