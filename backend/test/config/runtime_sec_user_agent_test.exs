defmodule Knowseek.RuntimeSecUserAgentTest do
  # Reads config/runtime.exs with a different environment variable each time.
  use ExUnit.Case, async: false

  @runtime Path.expand("../../config/runtime.exs", __DIR__)
  @default "Knowseek/0.1 (self-hosted instance)"

  defp edgar_config(value) do
    previous = System.get_env("SEC_USER_AGENT")

    if value,
      do: System.put_env("SEC_USER_AGENT", value),
      else: System.delete_env("SEC_USER_AGENT")

    on_exit(fn ->
      if previous,
        do: System.put_env("SEC_USER_AGENT", previous),
        else: System.delete_env("SEC_USER_AGENT")
    end)

    # The `dev` block of runtime.exs (the one that reads the variable) runs
    # for every environment but `test`.
    @runtime
    |> Config.Reader.read!(env: :dev, target: :host)
    |> get_in([:knowseek, Knowseek.Cards.Edgar])
  end

  test "an unset SEC_USER_AGENT leaves the default of config.exs" do
    assert edgar_config(nil) in [nil, []]
    assert Application.fetch_env!(:knowseek, Knowseek.Cards.Edgar)[:user_agent] == @default
  end

  test "an empty or blank SEC_USER_AGENT is the default too, not an empty header" do
    assert edgar_config("") in [nil, []]
    assert edgar_config("   ") in [nil, []]
  end

  test "a SEC_USER_AGENT is used, trimmed" do
    assert edgar_config("  Acme Corp ops@acme.example ") == [
             user_agent: "Acme Corp ops@acme.example"
           ]
  end
end
