defmodule Knowseek.Search.PgvectorCheckTest do
  use Knowseek.DataCase, async: false

  alias Knowseek.Search.PgvectorCheck

  describe "parse_version/1" do
    test "reads versions as numbers, not text" do
      assert PgvectorCheck.parse_version("0.8.0") == {:ok, {0, 8, 0}}
      assert PgvectorCheck.parse_version("0.8.7") == {:ok, {0, 8, 7}}
      assert PgvectorCheck.parse_version("0.10.1") == {:ok, {0, 10, 1}}
      assert PgvectorCheck.parse_version("1.0.0") == {:ok, {1, 0, 0}}
      assert PgvectorCheck.parse_version("0.8") == {:ok, {0, 8, 0}}
      assert PgvectorCheck.parse_version(" 0.9.2\n") == {:ok, {0, 9, 2}}

      # As text "0.10.1" < "0.8.7"; as numbers it is above.
      assert {:ok, a} = PgvectorCheck.parse_version("0.10.1")
      assert {:ok, b} = PgvectorCheck.parse_version("0.8.7")
      assert a > b
    end

    test "rejects what is not a version" do
      for bad <- ["", "0", "0.8.7.1", "a.b.c", "0.8.x", "0..1", "-0.8.0", "0.8.7-beta"] do
        assert PgvectorCheck.parse_version(bad) == :error, "expected :error for #{inspect(bad)}"
      end
    end
  end

  describe "check/2" do
    test "passes 0.8.0 and later for an iterative scan" do
      for version <- ["0.8.0", "0.8.7", "0.9.0", "0.10.1", "0.10.0", "1.0.0"],
          do: assert(PgvectorCheck.check(version, :strict_order) == :ok)
    end

    test "fails an older pgvector and names the config key and the minimum" do
      for version <- ["0.7.4", "0.7.99", "0.5.1", "0.4.0"] do
        assert {:error, message} = PgvectorCheck.check(version, :strict_order)
        assert message =~ "pgvector #{version}"
        assert message =~ "iterative_scan: :off"
        assert message =~ "0.8.0"
      end
    end

    test "fails a version it cannot read" do
      assert {:error, message} = PgvectorCheck.check("main", :strict_order)
      assert message =~ "unreadable"
      assert message =~ "iterative_scan: :off"
    end

    test "fails a missing extension and says to run the migrations" do
      assert {:error, message} = PgvectorCheck.check(nil, :strict_order)
      assert message =~ "not installed"
      assert message =~ "migrat"
      assert message =~ "strict_order"
    end

    test "passes any version, and a missing extension, with iterative_scan: :off" do
      for version <- ["0.7.4", "0.4.0", "main", nil],
          do: assert(PgvectorCheck.check(version, :off) == :ok)
    end
  end

  describe "check!/0 and start_link/1" do
    test "pass on the test database's pgvector" do
      [[version]] =
        Repo.query!("SELECT extversion FROM pg_extension WHERE extname = 'vector'").rows

      assert {:ok, parsed} = PgvectorCheck.parse_version(version)
      assert parsed >= {0, 8, 0}, "the test database needs pgvector 0.8 (docker-compose.yml)"

      assert PgvectorCheck.check!() == :ok
      assert PgvectorCheck.start_link([]) == :ignore
    end

    test "pass with iterative_scan: :off" do
      env = Application.fetch_env!(:knowseek, Knowseek.Search)
      on_exit(fn -> Application.put_env(:knowseek, Knowseek.Search, env) end)
      Application.put_env(:knowseek, Knowseek.Search, Keyword.put(env, :iterative_scan, :off))

      assert PgvectorCheck.check!() == :ok
      assert PgvectorCheck.start_link([]) == :ignore
    end
  end
end
