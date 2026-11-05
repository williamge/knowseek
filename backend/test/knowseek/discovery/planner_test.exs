defmodule Knowseek.Discovery.PlannerTest do
  # "the limits come from config" changes the global planner config.
  use ExUnit.Case, async: false

  alias Knowseek.Discovery.{FakePlanner, Planner}
  alias Knowseek.Discovery.Planner.Passthrough

  defp resolve(query, planned), do: resolve(query, planned, [])

  defp resolve(query, planned, opts) do
    FakePlanner.put(planned)
    Planner.resolve(query, Keyword.put(opts, :planner, FakePlanner))
  end

  describe "the configured planner" do
    test "is the pass-through in tests" do
      assert Planner.config(:adapter) == Passthrough
    end

    test "the pass-through returns the query as it is and says so" do
      assert Passthrough.plan("anything  AT all", []) == {:ok, ["anything  AT all"]}

      assert %{queries: ["Rust  Async"], status: :passthrough} =
               Planner.resolve("Rust  Async", [])
    end
  end

  describe "resolve/2" do
    test "puts the original query first, then the planned queries" do
      assert %{queries: ["tide pools", "intertidal zone", "rock pool"], status: :ok} =
               resolve("tide pools", ["intertidal zone", "rock pool"])

      assert_received {:fake_planner_asked, "tide pools"}
    end

    test "keeps the original first and once, even when the planner omits or repeats it" do
      assert %{queries: ["tide pools", "rock pool"]} =
               resolve("tide pools", ["Tide  Pools", "rock pool", "TIDE POOLS"])

      assert %{queries: ["tide pools"], status: :ok} = resolve("tide pools", [])
      assert %{queries: ["tide pools"], status: :ok} = resolve("tide pools", ["tide pools"])
    end

    test "never returns more than the original and three planned queries" do
      assert %{queries: [_original | planned]} = resolve("q", ~w(a b c d e f))
      assert planned == ~w(a b c)
    end

    test "the limits come from config" do
      config = Application.fetch_env!(:knowseek, Planner)

      Application.put_env(
        :knowseek,
        Planner,
        Keyword.merge(config, max_planned: 1, max_query_length: 4)
      )

      on_exit(fn -> Application.put_env(:knowseek, Planner, config) end)

      assert %{queries: ["q", "abcd"]} = resolve("q", ["abcdefgh", "other"])
    end

    test "a failing planner falls back to the original query" do
      assert %{queries: ["tide pools"], status: {:fallback, :model_missing}} =
               resolve("tide pools", {:error, :model_missing})
    end

    test "a planner that raises, exits, or throws falls back" do
      assert %{queries: ["q"], status: {:fallback, {:exception, "planner crashed"}}} =
               resolve("q", :raise)

      defmodule ExitingPlanner do
        @behaviour Knowseek.Discovery.Planner
        @impl true
        def plan(_query, _opts), do: exit(:shutdown)
      end

      assert %{queries: ["q"], status: {:fallback, {:exit, :shutdown}}} =
               Planner.resolve("q", planner: ExitingPlanner)
    end

    test "a planner that returns something else falls back" do
      assert %{queries: ["q"], status: {:fallback, {:invalid_plan, :nope}}} =
               resolve("q", {:ok, :nope})

      assert %{queries: ["q"], status: {:fallback, {:invalid_plan, :ok}}} = resolve("q", :ok)
    end
  end

  describe "clean/2" do
    test "drops what is not a string, empty strings, and invalid UTF-8" do
      assert Planner.clean([1, nil, :a, "", "  ", <<255, 254>>, "ok", ["x"]], "q") == ["ok"]
    end

    test "strips control and format characters and collapses whitespace" do
      assert Planner.clean(["a\u0000b\nc\td", "\u202Eevil\u202C  text", "x\u200By"], "q") ==
               ["a b c d", "evil text", "x y"]
    end

    test "keeps the zero-width non-joiner and joiner" do
      assert Planner.clean(["می\u200Cخواهم", "👩\u200D🔬 science"], "q") ==
               ["می\u200Cخواهم", "👩\u200D🔬 science"]
    end

    test "cuts to 100 characters, counting characters, not bytes" do
      assert [cut] = Planner.clean([String.duplicate("é", 150)], "q")
      assert String.length(cut) == 100

      assert Planner.clean([String.duplicate("a", 99) <> " b"], "q") == [
               String.duplicate("a", 99)
             ]
    end

    test "drops duplicates and the original, ignoring case and spacing" do
      assert Planner.clean(["A  b", "a B", "Q", "c"], "q") == ["A b", "c"]
    end

    test "keeps at most three" do
      assert Planner.clean(~w(a b c d), "q") == ~w(a b c)
      assert Planner.clean(for(n <- 1..10_000, do: "q#{n}"), "q") == ~w(q1 q2 q3)
    end
  end
end
