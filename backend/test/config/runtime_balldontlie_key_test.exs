defmodule Knowseek.RuntimeBalldontlieKeyTest do
  # Reads config/runtime.exs with a different environment variable each time.
  use ExUnit.Case, async: false

  @runtime Path.expand("../../config/runtime.exs", __DIR__)

  defp balldontlie_config(value) do
    previous = System.get_env("BALLDONTLIE_API_KEY")

    if value,
      do: System.put_env("BALLDONTLIE_API_KEY", value),
      else: System.delete_env("BALLDONTLIE_API_KEY")

    on_exit(fn ->
      if previous,
        do: System.put_env("BALLDONTLIE_API_KEY", previous),
        else: System.delete_env("BALLDONTLIE_API_KEY")
    end)

    # The `dev` block of runtime.exs (the one that reads the variable) runs
    # for every environment but `test`.
    @runtime
    |> Config.Reader.read!(env: :dev, target: :host)
    |> get_in([:knowseek, Knowseek.Cards.Balldontlie])
  end

  test "an unset BALLDONTLIE_API_KEY sets no key: no NBA card" do
    assert balldontlie_config(nil) in [nil, []]
  end

  test "an empty or blank BALLDONTLIE_API_KEY sets no key either" do
    assert balldontlie_config("") in [nil, []]
    assert balldontlie_config("   ") in [nil, []]
  end

  test "a BALLDONTLIE_API_KEY is used, trimmed" do
    assert balldontlie_config("  abc-123 ") == [api_key: "abc-123"]
  end
end
